defmodule SleeperPlayerApiWeb.IntelControllerTest do
  # `/intel` now makes a live `GET /league/:id/users` call (Gap 2 — see
  # `Intel.league_intel/2`'s moduledoc), so this suite points the Sleeper
  # client at a Bypass server via the shared `:sleeper_base_url` Application
  # env key (same trick as `AvailabilityControllerTest`), which means it
  # can't run concurrently with itself or anything else touching that key.
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel

  setup %{conn: conn} do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:sleeper_player_api, :sleeper_base_url) end)

    Intel.upsert_sleeper_users([
      %{id: 100, display_name: "alice"},
      %{id: 200, display_name: "bob"}
    ])

    Intel.upsert_observed_drafts([
      %{id: 601, league_id: 555, season: "2026", status: "complete", teams: 12, rounds: 1}
    ])

    Intel.upsert_observed_picks(601, [
      %{pick_no: 1, player_id: "P1", picked_by: 100},
      %{pick_no: 2, player_id: "P2", picked_by: 200}
    ])

    {:ok, conn: put_req_header(conn, "accept", "application/json"), bypass: bypass}
  end

  defp stub_league_users(bypass, league_id, users) do
    Bypass.stub(bypass, "GET", "/league/#{league_id}/users", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(users))
    end)
  end

  defp fail_league_users(bypass, league_id) do
    Bypass.stub(bypass, "GET", "/league/#{league_id}/users", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)
  end

  describe "GET /api/v1/leagues/:league_id/intel" do
    test "renders managers + corpus in the plan §3e camelCase shape", %{
      conn: conn,
      bypass: bypass
    } do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      conn = get(conn, ~p"/api/v1/leagues/555/intel?season=2026")
      body = json_response(conn, 200)

      assert %{"managers" => managers, "corpus" => corpus} = body
      # Strings: Sleeper ids exceed JavaScript's safe integer range, so the
      # API sends them as strings rather than let JSON.parse round them.
      assert Enum.map(managers, & &1["userId"]) == ["100", "200"]

      alice = Enum.find(managers, &(&1["userId"] == "100"))
      assert alice["displayName"] == "alice"
      assert is_integer(alice["leaguesCount"])
      assert is_integer(alice["draftsCount"])
      assert is_integer(alice["draftsComplete"])

      assert %{"crushes" => crushes, "positionLean" => lean, "reachVsAdp" => _} =
               alice["tendencies"]

      assert is_list(crushes)
      assert is_list(lean)

      assert corpus["drafts"] == 1
      assert corpus["picks"] == 2
      assert Map.has_key?(corpus, "lastCrawledAt")
      assert corpus["membershipSource"] == "live"
    end

    test "a league member with zero observed drafts still renders, with honest zeros", %{
      conn: conn,
      bypass: bypass
    } do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"},
        %{"user_id" => "300", "display_name" => "carol"}
      ])

      conn = get(conn, ~p"/api/v1/leagues/555/intel?season=2026")
      body = json_response(conn, 200)

      carol = Enum.find(body["managers"], &(&1["userId"] == "300"))
      assert carol["displayName"] == "carol"
      assert carol["draftsCount"] == 0
      assert carol["leaguesCount"] == 0
      assert carol["tendencies"]["crushes"] == []
      assert carol["tendencies"]["reachVsAdp"] == nil
    end

    test "an uncrawled league whose live members call also fails returns an empty managers list, not a 500 or 404",
         %{conn: conn, bypass: bypass} do
      fail_league_users(bypass, 999_999_999)

      conn = get(conn, ~p"/api/v1/leagues/999999999/intel?season=2026")
      body = json_response(conn, 200)

      assert body["managers"] == []
      assert body["corpus"]["drafts"] == 1
      assert body["corpus"]["membershipSource"] == "derived"
    end

    test "season is optional — omitting it still returns 200", %{conn: conn, bypass: bypass} do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      conn = get(conn, ~p"/api/v1/leagues/555/intel")
      assert json_response(conn, 200)["managers"] |> length() == 2
    end
  end
end
