defmodule SleeperPlayerApiWeb.LeagueRankingControllerTest do
  # Points the Sleeper, projections and FantasyCalc clients at Bypass through
  # shared Application env, so not async.
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Sleeper.{FantasyPositions, Player, Position}

  @league "424242"

  # Three teams, one player per position each. Team 1 is strong, team 3 weak,
  # and team 2 holds team 3's 2027 1st, which should therefore price early.
  @teams %{
    1 => %{"QB" => "101", "RB" => "102", "WR" => "103", "TE" => "104"},
    2 => %{"QB" => "201", "RB" => "202", "WR" => "203", "TE" => "204"},
    3 => %{"QB" => "301", "RB" => "302", "WR" => "303", "TE" => "304"}
  }
  @strength %{1 => 9000.0, 2 => 6000.0, 3 => 3000.0}

  setup do
    sleeper = Bypass.open()
    projections = Bypass.open()
    fantasy_calc = Bypass.open()

    for {key, bypass} <- [
          sleeper_base_url: sleeper,
          sleeper_projections_base_url: projections,
          fantasy_calc_base_url: fantasy_calc
        ] do
      Application.put_env(:sleeper_player_api, key, "http://localhost:#{bypass.port}")
    end

    MarketValuesCache.clear()

    on_exit(fn ->
      for key <- [:sleeper_base_url, :sleeper_projections_base_url, :fantasy_calc_base_url] do
        Application.delete_env(:sleeper_player_api, key)
      end

      MarketValuesCache.clear()
    end)

    {:ok, sleeper: sleeper, projections: projections, fantasy_calc: fantasy_calc}
  end

  defp position(abbreviation) do
    Repo.get_by(Position, abbreviation: abbreviation) ||
      Repo.insert!(%Position{abbreviation: abbreviation})
  end

  defp seed_player(player_id, abbreviation, opts \\ []) do
    pos = position(abbreviation)

    player =
      Repo.insert!(%Player{
        id: String.to_integer(player_id),
        player_id: player_id,
        full_name: "P #{player_id}",
        player_json: "{}",
        first_name: "P",
        last_name: player_id,
        search_first_name: "p",
        search_last_name: player_id,
        search_full_name: "p #{player_id}",
        position_id: pos.id,
        active: Keyword.get(opts, :active, true),
        injury_status: Keyword.get(opts, :injury_status)
      })

    Repo.insert!(%FantasyPositions{player_id: player.id, position_id: pos.id})
    player
  end

  defp value_row(player_id, source, value) do
    %{
      player_id: String.to_integer(player_id),
      source: source,
      value: value,
      overall_rank: 1,
      position_rank: 1,
      roster_percent: nil,
      trade_frequency: nil,
      draft_year: nil,
      as_of: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp seed_values(sources) do
    for {roster_id, players} <- @teams, {_pos, id} <- players, source <- sources do
      value_row(id, source, @strength[roster_id])
    end
    |> Intel.upsert_player_values()

    if "keeptradecut:sf" in sources do
      for round <- 1..2,
          {tier, value} <- [{"early", 5000.0}, {"mid", 3000.0}, {"late", 2000.0}] do
        %{
          season: 2027,
          round: round,
          tier: tier,
          source: "keeptradecut:sf",
          value: value / round,
          overall_rank: nil,
          position_rank: nil,
          as_of: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      end
      |> Intel.upsert_draft_pick_values()
    end
  end

  defp seed_players do
    for {_roster, players} <- @teams, {pos, id} <- players, do: seed_player(id, pos)
  end

  defp league(overrides) do
    Map.merge(
      %{
        "league_id" => @league,
        "name" => "Test League",
        "season" => "2026",
        "status" => "in_season",
        "total_rosters" => 12,
        "roster_positions" => ["QB", "RB", "WR", "TE", "SUPER_FLEX", "BN"],
        "scoring_settings" => %{"rec" => 1.0, "rec_yd" => 0.1},
        "settings" => %{"type" => 2, "draft_rounds" => 2, "playoff_week_start" => 15}
      },
      overrides
    )
  end

  defp rosters do
    for {roster_id, players} <- @teams do
      %{
        "roster_id" => roster_id,
        "owner_id" => "u#{roster_id}",
        "players" => Map.values(players),
        "reserve" => [],
        "taxi" => [],
        "settings" => %{"wins" => 0, "losses" => 0, "ties" => 0, "fpts" => 0}
      }
    end
  end

  defp stub_sleeper(bypass, opts \\ []) do
    responses = %{
      "/league/#{@league}" => {200, Keyword.get(opts, :league, league(%{}))},
      "/league/#{@league}/rosters" => {200, rosters()},
      "/league/#{@league}/users" =>
        {200, for(id <- 1..3, do: %{"user_id" => "u#{id}", "display_name" => "Manager #{id}"})},
      "/league/#{@league}/drafts" =>
        {200, [%{"season" => "2026", "status" => "complete", "type" => "linear"}]},
      "/league/#{@league}/traded_picks" =>
        Keyword.get(
          opts,
          :traded_picks,
          {200, [%{"season" => "2027", "round" => 1, "roster_id" => 3, "owner_id" => 2}]}
        )
    }

    for {path, {status, body}} <- responses do
      Bypass.stub(bypass, "GET", path, fn conn ->
        Plug.Conn.resp(conn, status, Jason.encode!(body))
      end)
    end
  end

  defp projection_rows do
    for {roster_id, players} <- @teams, {_pos, id} <- players do
      %{
        "player_id" => id,
        "last_modified" => 1_790_754_624_517,
        "stats" => %{
          "rec" => 100 - roster_id * 20,
          "rec_yd" => 1000,
          "adp_2qb" => roster_id * 10.0
        }
      }
    end
  end

  defp stub_projections(bypass) do
    Bypass.expect_once(bypass, "GET", "/projections/nfl/2026", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(projection_rows()))
    end)
  end

  defp team(body, roster_id), do: Enum.find(body["teams"], &(&1["rosterId"] == roster_id))

  describe "GET /api/v1/leagues/:league_id/rankings" do
    setup %{sleeper: sleeper, projections: projections} do
      seed_players()
      seed_values(["keeptradecut:sf", "fantasycalc"])
      stub_sleeper(sleeper)
      stub_projections(projections)
      :ok
    end

    test "ranks every team on every source, best first", %{conn: conn} do
      body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

      assert length(body["teams"]) == 3
      assert Enum.map(body["teams"], & &1["rosterId"]) == [1, 2, 3]
      assert team(body, 1)["rank"]["now"] == 1
      assert team(body, 3)["rank"] == %{"now" => 3, "future" => 3}
      # Everyone starts their whole roster, so Future is pick capital alone,
      # and team 2 is the only one that has bought any.
      assert team(body, 2)["rank"]["future"] == 1
      assert team(body, 1)["name"] == "Manager 1"

      assert team(body, 1)["now"] |> Map.keys() |> Enum.sort() ==
               ~w(adp blend fc ktc proj)

      assert team(body, 1)["tier"] in ~w(contender all-in)
      assert Enum.map(body["sources"], & &1["id"]) == ~w(ktc fc projections)
      assert body["missing"] == []
      assert length(body["tiers"]) == 5
    end

    test "prices a weak team's traded 1st as early, for the team that holds it", %{conn: conn} do
      body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

      picks = team(body, 2)["futureDetail"]["picks"]

      assert %{"basis" => "projected", "tier" => "early", "value" => 5000.0} =
               Enum.find(picks, &(&1["round"] == 1 and &1["originalRosterId"] == 3))

      # Holding a pick bought from someone else is net pick capital; holding
      # only your own is neutral.
      assert team(body, 2)["netPickValue"] > 0
      assert team(body, 1)["netPickValue"] == 0
    end

    test "fetches a season's projections once, then reads them from the table", %{conn: conn} do
      # `stub_projections/1` is `expect_once`: a second fetch would fail it.
      conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)
      body = build_conn() |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

      assert length(Intel.projections(2026)) == 12
      assert %{"provider" => "sleeper", "asOf" => "2026-09-30T" <> _} = List.last(body["sources"])
    end

    test "states the format gaps the market does not price", %{conn: conn, sleeper: sleeper} do
      stub_sleeper(sleeper,
        league:
          league(%{
            "roster_positions" => ["QB", "QB", "RB", "WR", "TE", "SUPER_FLEX", "BN"],
            "scoring_settings" => %{"rec" => 1.0, "bonus_rec_te" => 0.5}
          })
      )

      body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

      assert body["format"]["numQbs"] == 3
      assert body["format"]["tePremium"] == 0.5
      assert Enum.map(body["notes"], & &1["code"]) == ~w(qb_count_unpriced te_premium_unpriced)
    end
  end

  test "leaves picks out, and says so, when traded picks cannot be read", %{
    conn: conn,
    sleeper: sleeper,
    projections: projections
  } do
    seed_players()
    seed_values(["keeptradecut:sf", "fantasycalc"])
    stub_sleeper(sleeper, traded_picks: {500, %{}})
    stub_projections(projections)

    body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

    assert [%{"id" => "picks"}] = body["missing"]
    assert Enum.all?(body["teams"], &(&1["netPickValue"] == nil))
    assert Enum.all?(body["teams"], &(&1["futureDetail"]["picks"] == []))
  end

  test "ranks without FantasyCalc when its fetch fails", %{
    conn: conn,
    sleeper: sleeper,
    projections: projections,
    fantasy_calc: fantasy_calc
  } do
    # A 10-team league is not the stored slice, so FantasyCalc is fetched live.
    seed_players()
    seed_values(["keeptradecut:sf"])
    stub_sleeper(sleeper, league: league(%{"total_rosters" => 10}))
    stub_projections(projections)
    Bypass.stub(fantasy_calc, "GET", "/values/current", &Plug.Conn.resp(&1, 500, "down"))

    body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

    assert [%{"id" => "fc", "reason" => "FantasyCalc fetch failed: " <> _}] = body["missing"]
    assert Enum.map(body["sources"], & &1["id"]) == ~w(ktc projections)
    refute Map.has_key?(team(body, 1)["now"], "fc")
  end

  test "an inactive player is not started, as the app's player list omits him", %{
    conn: conn,
    sleeper: sleeper,
    projections: projections
  } do
    for {roster, players} <- @teams, {pos, id} <- players do
      seed_player(id, pos, active: not (roster == 1 and pos == "QB"))
    end

    seed_values(["keeptradecut:sf", "fantasycalc"])
    stub_sleeper(sleeper)
    stub_projections(projections)

    body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(200)

    started = team(body, 1)["lineups"]["ktc"]["starters"] |> Enum.map(& &1["playerId"])
    refute "101" in started
  end

  test "is a 503 with no KeepTradeCut values stored", %{
    conn: conn,
    sleeper: sleeper,
    projections: projections
  } do
    seed_players()
    stub_sleeper(sleeper)
    Bypass.stub(projections, "GET", "/projections/nfl/2026", &Plug.Conn.resp(&1, 200, "[]"))

    body = conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(503)

    assert body["errors"]["detail"] =~ "no dynasty values"
  end

  test "is a 404 for a league Sleeper does not know", %{conn: conn, sleeper: sleeper} do
    Bypass.stub(sleeper, "GET", "/league/#{@league}", &Plug.Conn.resp(&1, 404, "null"))

    conn |> get(~p"/api/v1/leagues/#{@league}/rankings") |> json_response(404)
  end
end
