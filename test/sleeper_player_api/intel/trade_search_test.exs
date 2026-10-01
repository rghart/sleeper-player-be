defmodule SleeperPlayerApi.Intel.TradeSearchTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.{LeagueRankings, Projections, TradeSearch, TradeValue, TradeWindow}

  # The real (anonymised) League of Boredom fixture: twelve rosters, live
  # values and projections. Every idea the search returns must hold the
  # invariants below, whatever it finds.
  setup_all do
    fixture =
      Path.expand("../../support/fixtures/power_rankings/sf_te05_12t.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    i = fixture["inputs"]

    teams =
      LeagueRankings.rank(%{
        league: i["league"],
        rosters: i["rosters"],
        users: i["users"],
        player_info: i["playerInfo"],
        ktc: i["inputs"]["ktc"],
        fc: i["inputs"]["fc"],
        traded_picks: i["inputs"]["tradedPicks"],
        projections: i["inputs"]["projections"],
        current_draft_complete: i["currentDraftComplete"],
        draft: i["draft"]
      })

    snapshot = %{
      league: i["league"],
      rosters: i["rosters"],
      teams: teams,
      player_info: i["playerInfo"],
      ktc_values: Map.new(i["inputs"]["ktc"]["values"], &{&1["playerId"], &1["value"]}),
      projected_points:
        Projections.projection_values(i["inputs"]["projections"], i["league"]["scoring_settings"])
    }

    context = TradeSearch.context(snapshot, TradeWindow.context(snapshot, %{}))
    rosters = Map.new(i["rosters"], &{to_string(&1["owner_id"]), &1["players"]})

    ideas =
      for mode <- TradeSearch.modes(), user <- Map.keys(rosters), into: %{} do
        {:ok, ideas} = TradeSearch.ideas(context, user, mode)
        {{mode, user}, ideas}
      end

    %{context: context, rosters: rosters, ideas: ideas}
  end

  defp all(ideas), do: for({{mode, user}, list} <- ideas, idea <- list, do: {mode, user, idea})

  test "finds ideas in every mode", %{ideas: ideas} do
    for mode <- TradeSearch.modes() do
      assert Enum.any?(ideas, fn {{m, _}, list} -> m == mode and list != [] end), mode
    end
  end

  test "every idea is even on market value, within the band", %{ideas: ideas, context: context} do
    for {_mode, _user, idea} <- all(ideas) do
      gap = abs(idea.get_value - idea.give_value) / max(idea.give_value, idea.get_value)
      assert gap <= 0.12 + 1.0e-9

      # And the numbers are what TradeValue says for the pieces involved.
      give = Enum.map(idea.give, &context.values[&1]) ++ Enum.map(idea.give_picks, & &1.value)
      get = Enum.map(idea.get, &context.values[&1]) ++ Enum.map(idea.get_picks, & &1.value)
      assert TradeValue.evaluate(give, get, context.top_value).one.adjusted == idea.give_value
    end
  end

  test "you give only your own players and get only theirs, none twice", %{
    ideas: ideas,
    rosters: rosters
  } do
    for {_mode, user, idea} <- all(ideas) do
      assert Enum.all?(idea.give, &(&1 in rosters[user]))
      assert Enum.all?(idea.get, &(&1 in rosters[idea.partner_id]))
      assert length(Enum.uniq(idea.give ++ idea.get)) == length(idea.give ++ idea.get)
      refute idea.partner_id == user
    end
  end

  test "pieces added to even a trade are capped by value, not by count", %{
    ideas: ideas,
    context: context
  } do
    added = for {_mode, _user, %{added: a} = idea} <- all(ideas), a != nil, do: {a, idea}
    assert added != [], "expected some ideas to need evening"

    for {a, idea} <- added do
      value =
        Enum.sum(Enum.map(a.picks, & &1.value)) +
          Enum.sum(Enum.map(a.players, &context.values[&1]))

      # The cap is a share of the larger side of the package as first
      # proposed, before the additions went on the side that was behind.
      {give_before, get_before} =
        if a.side == :give,
          do: {idea.give_raw - value, idea.get_raw},
          else: {idea.give_raw, idea.get_raw - value}

      assert value <= 0.35 * max(give_before, get_before) + 1.0e-6
    end
  end

  test "each mode's ideas pass that mode's rule", %{ideas: ideas} do
    for {mode, _user, idea} <- all(ideas) do
      case mode do
        "window" ->
          assert idea.my_window.gain > 0 and idea.their_window.gain > 0

        "win_now" ->
          assert idea.my_window.now > 0 and idea.their_window.gain >= 0

        "market" ->
          assert idea.get_value > idea.give_value and idea.their_window.gain >= 0
      end
    end
  end

  test "is not limited to small trades", %{ideas: ideas} do
    sizes = for {_m, _u, idea} <- all(ideas), do: length(idea.give) + length(idea.get)
    assert Enum.max(sizes) >= 5
  end

  test "ranks each manager's ideas best first", %{ideas: ideas} do
    for {_key, list} <- ideas do
      scores = Enum.map(list, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  test "rejects an unknown mode and a manager not in the league", %{context: context} do
    assert TradeSearch.ideas(context, "1001", "vibes") == {:error, {:invalid_mode, "vibes"}}
    assert TradeSearch.ideas(context, "nobody", "window") == {:error, :not_in_league}
  end
end
