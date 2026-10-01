defmodule SleeperPlayerApiWeb.UserSummaryControllerTest do
  # Points the Sleeper and projections clients at Bypass through shared
  # Application env, so not async.
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.{LeagueSnapshotCache, MarketValuesCache}
  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Sleeper.{FantasyPositions, Player, Position}

  setup do
    sleeper = Bypass.open()
    projections = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :sleeper_base_url,
      "http://localhost:#{sleeper.port}"
    )

    Application.put_env(
      :sleeper_player_api,
      :sleeper_projections_base_url,
      "http://localhost:#{projections.port}"
    )

    MarketValuesCache.clear()
    LeagueSnapshotCache.clear()

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :sleeper_base_url)
      Application.delete_env(:sleeper_player_api, :sleeper_projections_base_url)
      MarketValuesCache.clear()
      LeagueSnapshotCache.clear()
    end)

    # No projections: the summary must work on market values alone.
    Bypass.stub(projections, "GET", "/projections/nfl/2026", &Plug.Conn.resp(&1, 200, "[]"))

    {:ok, sleeper: sleeper}
  end

  defp position(abbreviation) do
    Repo.get_by(Position, abbreviation: abbreviation) ||
      Repo.insert!(%Position{abbreviation: abbreviation})
  end

  defp seed_player(player_id, abbreviation, value, age) do
    pos = position(abbreviation)

    player =
      Repo.insert!(%Player{
        # Stored values are keyed by the Sleeper id as an integer, as in
        # production, so test ids are numeric too.
        id: String.to_integer(player_id),
        player_id: player_id,
        full_name: player_id,
        player_json: "{}",
        first_name: "P",
        last_name: player_id,
        search_first_name: "p",
        search_last_name: player_id,
        search_full_name: player_id,
        position_id: pos.id,
        active: true,
        age: age
      })

    Repo.insert!(%FantasyPositions{player_id: player.id, position_id: pos.id})

    for source <- ["keeptradecut:sf", "fantasycalc"] do
      Intel.upsert_player_values([
        %{
          player_id: player.id,
          source: source,
          value: value,
          overall_rank: 1,
          position_rank: 1,
          roster_percent: nil,
          trade_frequency: nil,
          draft_year: nil,
          as_of: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])
    end

    player_id
  end

  # Three-team leagues, QB/RB/WR/TE plus a superflex. "500" is a 28-year-old
  # RB worth 9,000 who is on the user's roster in both dynasty leagues.
  defp seed_players do
    seed_player("500", "RB", 9000.0, 28)

    for {prefix, value} <- [{1, 9000.0}, {2, 6000.0}, {3, 4000.0}, {4, 100.0}],
        {pos, n} <- [{"QB", 1}, {"RB", 2}, {"WR", 3}, {"TE", 4}] do
      seed_player("#{prefix}0#{n}", pos, value, 24)
    end
  end

  defp league(id, type, rosters) do
    %{
      league_id: id,
      body: %{
        "league_id" => id,
        "name" => "League #{id}",
        "season" => "2026",
        "status" => "in_season",
        "total_rosters" => 12,
        "roster_positions" => ["QB", "RB", "WR", "TE", "SUPER_FLEX", "BN"],
        "scoring_settings" => %{"rec" => 1.0},
        "settings" => %{"type" => type, "draft_rounds" => 0}
      },
      rosters:
        for {{owner, players}, roster_id} <- Enum.with_index(rosters, 1) do
          %{"roster_id" => roster_id, "owner_id" => owner, "players" => players}
        end
    }
  end

  defp leagues do
    [
      # The user contends here, starting "500" at RB.
      league("L1", 2, [
        {"u1", ~w(101 500 103 104)},
        {"x", ~w(201 202 203 204)},
        {"y", ~w(301 302 303 304)}
      ]),
      # The user is the weak team here, with "500" past his cliff.
      league("L2", 2, [
        {"x", ~w(201 202 203 204)},
        {"y", ~w(301 302 303 304)},
        {"u1", ~w(401 500 403 404)}
      ]),
      league("L3", 0, [{"u1", ~w(101)}]),
      league("L4", 2, [{"x", ~w(201 202 203 204)}, {"y", ~w(301 302 303 304)}]),
      # Has not drafted: every roster empty, the user's included.
      league("L5", 2, [{"u1", []}, {"x", []}, {"y", []}])
    ]
  end

  defp json(conn, body), do: Plug.Conn.resp(conn, 200, Jason.encode!(body))

  defp stub_sleeper(sleeper) do
    Bypass.stub(
      sleeper,
      "GET",
      "/user/ryan",
      &json(&1, %{"user_id" => "u1", "username" => "ryan"})
    )

    Bypass.stub(sleeper, "GET", "/state/nfl", &json(&1, %{"league_season" => "2026"}))

    bodies = Enum.map(leagues(), & &1.body)
    Bypass.stub(sleeper, "GET", "/user/u1/leagues/nfl/2026", &json(&1, bodies))

    for l <- leagues() do
      users =
        for r <- l.rosters, do: %{"user_id" => r["owner_id"], "display_name" => r["owner_id"]}

      for {path, body} <- [
            {"", l.body},
            {"/rosters", l.rosters},
            {"/users", users},
            {"/drafts", []},
            {"/traded_picks", []}
          ] do
        Bypass.stub(sleeper, "GET", "/league/#{l.league_id}#{path}", &json(&1, body))
      end
    end
  end

  defp by_id(body), do: Map.new(body["leagues"], &{&1["leagueId"], &1})

  test "summarises every dynasty league, and says why the rest were skipped", %{
    conn: conn,
    sleeper: sleeper
  } do
    seed_players()
    stub_sleeper(sleeper)

    body = conn |> get(~p"/api/v1/users/ryan/summary") |> json_response(200)
    leagues = by_id(body)

    assert body["user"]["userId"] == "u1"
    assert body["season"] == "2026"
    assert Enum.map(body["leagues"], & &1["leagueId"]) == ~w(L1 L2 L3 L4 L5)

    contender = leagues["L1"]
    assert contender["tier"] == "contender"
    assert contender["rank"] == %{"now" => 1, "future" => 1}
    assert length(contender["topAssets"]) == 4
    assert "500" in Enum.map(contender["topAssets"], & &1["playerId"])
    assert contender["sells"] == []

    rebuilder = leagues["L2"]
    assert rebuilder["tier"] in ["rebuilding", "stuck"]
    assert rebuilder["rank"]["now"] == 3
    assert [%{"playerId" => "500", "position" => "RB", "age" => 28}] = rebuilder["sells"]
    assert rebuilder["topWeakness"]["group"] in ~w(QB WR TE FLEX)

    assert leagues["L3"]["skipped"] =~ "redraft"
    assert leagues["L4"]["skipped"] =~ "no roster"
    assert leagues["L5"]["skipped"] =~ "has not drafted"
    refute Map.has_key?(leagues["L5"], "tier")
  end

  test "names a player to sell in one league and keep in another", %{conn: conn, sleeper: sleeper} do
    seed_players()
    stub_sleeper(sleeper)

    body = conn |> get(~p"/api/v1/users/ryan/summary") |> json_response(200)

    assert body["crossLeague"] == [%{"playerId" => "500", "sellIn" => ["L2"], "holdIn" => ["L1"]}]
  end

  test "lists a league that fails to load with its error, and still answers the rest", %{
    conn: conn,
    sleeper: sleeper
  } do
    seed_players()
    stub_sleeper(sleeper)
    Bypass.stub(sleeper, "GET", "/league/L2/rosters", &Plug.Conn.resp(&1, 500, "down"))

    leagues = conn |> get(~p"/api/v1/users/ryan/summary") |> json_response(200) |> by_id()

    assert leagues["L2"]["error"] =~ "500"
    assert leagues["L1"]["tier"] == "contender"
  end

  test "is a 404 for a user Sleeper does not know", %{conn: conn, sleeper: sleeper} do
    Bypass.stub(sleeper, "GET", "/user/nobody", &Plug.Conn.resp(&1, 404, "null"))

    conn |> get(~p"/api/v1/users/nobody/summary") |> json_response(404)
  end
end
