defmodule SleeperPlayerApiWeb.PlayerValueSettingsTest do
  # Bypass owns a real port and this points the FantasyCalc client at it, same
  # as every other Bypass-backed suite here — cannot run concurrently.
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.MarketValuesCache

  setup %{conn: conn} do
    bypass = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :fantasy_calc_base_url,
      "http://localhost:#{bypass.port}"
    )

    MarketValuesCache.clear()

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :fantasy_calc_base_url)
      MarketValuesCache.clear()
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), bypass: bypass}
  end

  defp stored(player_id, overall_rank) do
    Intel.upsert_player_values([
      %{
        player_id: player_id,
        source: "fantasycalc",
        value: 1000.0,
        overall_rank: overall_rank,
        position_rank: 1,
        as_of: ~U[2026-08-10 08:30:00Z],
        draft_year: 2025
      }
    ])
  end

  defp live_entry(sleeper_id, overall_rank) do
    %{
      "player" => %{
        "name" => "Player #{sleeper_id}",
        "sleeperId" => sleeper_id,
        "position" => "WR"
      },
      "value" => 500.0,
      "overallRank" => overall_rank,
      "positionRank" => 1,
      "maybeRosterPercent" => 0.5,
      "maybeTradeFrequency" => 0.02
    }
  end

  # The stored slice is answerable without leaving the building. Anything else
  # is a fetch, so a test that expects no fetch is asserting the fast path.
  describe "the stored slice" do
    test "is served from the database without calling the provider", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)
      stored(1, 1)

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1"]
    end

    test "is still the stored slice when its settings are stated explicitly", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.down(bypass)
      stored(1, 1)

      body =
        conn
        |> get(~p"/api/v1/values?dynasty=true&num_qbs=2&num_teams=12&ppr=1")
        |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1"]
    end
  end

  describe "another league shape" do
    test "is fetched from the provider", %{conn: conn, bypass: bypass} do
      stored(1, 1)

      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        # The league that was asked about is the league that gets fetched.
        assert conn.query_params["numQbs"] == "1"
        assert conn.query_params["numTeams"] == "10"
        assert conn.query_params["ppr"] == "0.5"
        Plug.Conn.resp(conn, 200, Jason.encode!([live_entry("77", 1)]))
      end)

      body = conn |> get(~p"/api/v1/values?num_qbs=1&num_teams=10&ppr=0.5") |> json_response(200)

      # The live rows, not the stored one.
      assert Enum.map(body["values"], & &1["playerId"]) == ["77"]
    end

    test "echoes the settings it answered, including the ones that fell back", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!([live_entry("77", 1)]))
      end)

      body = conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(200)

      assert body["settings"] == %{
               "source" => "fantasycalc",
               "format" => "dynasty",
               "numQbs" => 2,
               "numTeams" => 10,
               "ppr" => 1.0
             }
    end

    test "reports a redraft league as redraft", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        assert conn.query_params["isDynasty"] == "false"
        Plug.Conn.resp(conn, 200, Jason.encode!([live_entry("77", 1)]))
      end)

      body = conn |> get(~p"/api/v1/values?dynasty=false") |> json_response(200)

      assert body["settings"]["format"] == "redraft"
    end

    # FantasyCalc is a free public API and this app is a guest: pressing the
    # import button twice must not be two third-party requests.
    test "is fetched once and then cached", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!([live_entry("77", 1)]))
      end)

      first = conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(200)
      second = conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(200)

      assert first["values"] == second["values"]
    end

    test "caches each league shape separately", %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "GET", "/values/current", fn conn ->
        id = if conn.query_params["numTeams"] == "10", do: "10", else: "14"
        Plug.Conn.resp(conn, 200, Jason.encode!([live_entry(id, 1)]))
      end)

      ten = conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(200)
      fourteen = conn |> get(~p"/api/v1/values?num_teams=14") |> json_response(200)

      assert Enum.map(ten["values"], & &1["playerId"]) == ["10"]
      assert Enum.map(fourteen["values"], & &1["playerId"]) == ["14"]
    end

    test "sorts a live slice best player first, nulls last", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        entries = [live_entry("3", 3), live_entry("9", nil), live_entry("1", 1)]
        Plug.Conn.resp(conn, 200, Jason.encode!(entries))
      end)

      body = conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1", "3", "9"]
    end

    test "says so when the provider cannot be reached", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)

      assert conn |> get(~p"/api/v1/values?num_teams=10") |> json_response(502)
    end
  end

  describe "a request that cannot be read" do
    test "is rejected rather than quietly substituted", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)

      body = conn |> get(~p"/api/v1/values?num_teams=twelve") |> json_response(422)

      assert body["errors"]["detail"] =~ "must be an integer"
    end

    # 999 *is* an integer. Reusing the invalid_param message here would tell
    # the caller something false about their input.
    test "names the bounds when a good number is out of range", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)

      body = conn |> get(~p"/api/v1/values?num_teams=999") |> json_response(422)

      assert body["errors"]["detail"] =~ "must be between 2 and 32"
    end
  end
end
