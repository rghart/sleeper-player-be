defmodule SleeperPlayerApi.Intel.LeagueRankings do
  @moduledoc """
  Ranks one league from its Sleeper data and the value lists it rests on.

  Ported from `rankLeague` in the frontend's `src/lib/leagueRankings.js`. This
  is the orchestration; the rules live in `PowerRankings`, `PickSlots` and
  `Projections`. Pure: the caller fetches, this decides.

  Inputs, all as decoded JSON (string keys), which is also what the parity
  fixtures hold:

    * `league`, `rosters`, `users`: Sleeper's `/league/:id`, `/rosters`, `/users`
    * `player_info`: `%{player_id => %{"position", "fantasy_positions", "injury_status"}}`
    * `ktc`: this API's `/dynasty-values` response (`"values"` and `"picks"`)
    * `fc`: this API's `/values` response for the league's settings, or nil
    * `traded_picks`: Sleeper's `/league/:id/traded_picks`, or nil
    * `projections`: Sleeper's season projections, or nil
    * `current_draft_complete`: whether this season's rookie draft is done, or
      nil to read it off the league's status
    * `draft`: the league's current draft, or nil

  Each input but KTC only removes something when missing: without projections
  there are no projection or ADP sources, without FantasyCalc no FC source,
  and without traded picks no picks at all (crediting every team with its own
  picks would be a claim nothing here can back). Without KTC there is no
  Future score, so the answer is nil.
  """

  alias SleeperPlayerApi.Intel.{
    MarketSettings,
    PickHoldings,
    PickSlots,
    PowerRankings,
    Projections
  }

  @doc "One ranked team per roster, in roster order, or nil when the league cannot be ranked."
  def rank(input) do
    if input[:ktc] && input[:league] && input[:rosters] not in [nil, []], do: rank_league(input)
  end

  defp rank_league(input) do
    %{league: league, ktc: ktc} = input
    rosters = decorate(input.rosters, input[:users] || [])

    # The caller may know the draft's own status; failing that, the league's
    # says the same thing a step removed: a dynasty league is `pre_draft` or
    # `drafting` until this season's rookie draft is done.
    draft_done =
      case input[:current_draft_complete] do
        nil -> league["status"] not in ["pre_draft", "drafting"]
        done -> done
      end

    superflex = league |> MarketSettings.from_league() |> MarketSettings.superflex?()
    ktc_by_id = values_by_player_id(ktc)
    fc_by_id = values_by_player_id(input[:fc])
    ktc_value = fn id -> ktc_by_id[id] end

    sources =
      case input[:projections] do
        rows when is_list(rows) and rows != [] ->
          scoring = league["scoring_settings"]
          points = Projections.projection_values(rows, scoring)
          adp = Projections.adp_values(rows, superflex, scoring && scoring["rec"])
          [proj: fn id -> points[id] end, adp: fn id -> adp[id] end]

        _ ->
          []
      end

    sources = sources ++ [ktc: ktc_value]
    sources = if input[:fc], do: sources ++ [fc: fn id -> fc_by_id[id] end], else: sources

    base = %{
      rosters: rosters,
      roster_positions: league["roster_positions"],
      player_info: input.player_info,
      sources: sources,
      future: ktc_value
    }

    case input[:traded_picks] do
      traded when is_list(traded) -> rank_with_picks(base, traded, input, draft_done)
      _ -> PowerRankings.rank_teams(Map.put(base, :picks, nil))
    end
  end

  # Two passes. A pick's price depends on where its original team finishes,
  # which depends on that team's Now score, but Now never depends on picks.
  # So a first pass with every pick at "mid" gets Now exactly, and the second
  # prices each pick from it.
  defp rank_with_picks(base, traded, input, draft_done) do
    %{league: league, ktc: ktc} = input
    rosters = base.rosters

    seasons =
      (ktc["picks"] || [])
      |> Enum.map(& &1["season"])
      |> PowerRankings.pick_seasons_in_scope(league["season"], draft_done)

    picks_base = %{
      seasons: seasons,
      rounds: get_in(league, ["settings", "draft_rounds"]) || 0,
      traded_picks: traded
    }

    price_of = fn pick -> fn tier -> pick_value(ktc, pick.season, pick.round, tier) end end

    first_pass =
      PowerRankings.rank_teams(
        Map.put(base, :picks, Map.put(picks_base, :value_of, &price_of.(&1).("mid")))
      )

    next_season = List.first(seasons)
    draft = input[:draft]

    # A draft order counts only for the draft it belongs to, and only before
    # that draft has run.
    upcoming =
      if draft && PickHoldings.to_season(draft["season"]) == next_season &&
           draft["status"] != "complete",
         do: draft

    context = %{
      next_season: next_season,
      finish: PickSlots.projected_finish(first_pass, rosters, league),
      team_count: length(rosters),
      slots: PickSlots.draft_slots(upcoming, rosters),
      draft: upcoming,
      season_over: PickSlots.season_progress(rosters, league) >= 1
    }

    PowerRankings.rank_teams(
      Map.put(
        base,
        :picks,
        Map.put(picks_base, :value_of, &PickSlots.price_pick(&1, context, price_of.(&1)))
      )
    )
  end

  # Each roster's manager name, resolved against the league's users. A roster
  # with no matching manager reads "Unassigned <roster_id>", as in the app.
  defp decorate(rosters, users) do
    names = Map.new(users, &{&1["user_id"], &1["display_name"]})

    Enum.map(rosters, fn roster ->
      name = Map.get(names, roster["owner_id"]) || "Unassigned #{roster["roster_id"]}"
      Map.put(roster, "manager_display_name", name)
    end)
  end

  # A value response's players keyed by Sleeper id. Ids are strings on the
  # wire and on rosters, so nothing is coerced; a map keyed by number and read
  # by string silently misses every player.
  defp values_by_player_id(%{"values" => values}) when is_list(values) do
    for %{"playerId" => id, "value" => value} when id != nil <- values,
        into: %{},
        do: {to_string(id), value}
  end

  defp values_by_player_id(_), do: %{}

  # The first pick entry for this season, round and tier; nil when unpriced.
  defp pick_value(ktc, season, round, tier) do
    entry =
      Enum.find(ktc["picks"] || [], fn pick ->
        PickHoldings.to_season(pick["season"]) == season and pick["round"] == round and
          pick["tier"] == tier
      end)

    entry && entry["value"]
  end
end
