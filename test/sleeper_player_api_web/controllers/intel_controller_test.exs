defmodule SleeperPlayerApiWeb.IntelControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.Intel

  setup %{conn: conn} do
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

    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/v1/leagues/:league_id/intel" do
    test "renders managers + corpus in the plan §3e camelCase shape", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/leagues/555/intel?season=2026")
      body = json_response(conn, 200)

      assert %{"managers" => managers, "corpus" => corpus} = body
      assert Enum.map(managers, & &1["userId"]) == [100, 200]

      alice = Enum.find(managers, &(&1["userId"] == 100))
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
    end

    test "an uncrawled league returns an empty managers list, not a 500 or 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/leagues/999999999/intel?season=2026")
      body = json_response(conn, 200)

      assert body["managers"] == []
      assert body["corpus"]["drafts"] == 1
    end

    test "season is optional — omitting it still returns 200", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/leagues/555/intel")
      assert json_response(conn, 200)["managers"] |> length() == 2
    end
  end
end
