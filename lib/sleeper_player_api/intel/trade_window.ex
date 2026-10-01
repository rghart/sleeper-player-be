defmodule SleeperPlayerApi.Intel.TradeWindow do
  @moduledoc """
  What a trade is worth to a team **in its window** (docs/dynasty-engine.md,
  M4): a contender buys this season, a rebuilder buys the future, and a team
  in the middle weighs both.

  `TradeFinder` decides whether two rosters *fit* and whether a trade is
  *fair*. This decides whether each side would *want* it, which is the part a
  finder that knows nothing about windows gets wrong: a fair, well-fitting
  swap that costs a contender a starter is not a trade it makes.

  For one side of a trade:

    * **now gain**: the change in its best starting lineup under the league's
      win-now values (projected points scored with the league's settings;
      KeepTradeCut when there are no projections), as a share of the league's
      average lineup.
    * **future gain**: the change in its future capital, meaning KeepTradeCut
      value of players short of their position's age cliff, plus picks, as a
      share of the league's average. A player past the cliff counts as
      nothing here, which is the point: shedding one is a rebuilder's gain,
      taking one on is its loss.
    * **gain**: now for Contender and All-in, future for Rebuilding and Stuck,
      the mean of the two for Middle.

  Shares rather than raw numbers, so a gain in projected points and a gain in
  KTC value can be compared, and so can two leagues.

  Pure: `context/2` reads a `LeagueSnapshot` once; `gain/6` is arithmetic.
  """

  alias SleeperPlayerApi.Intel.{Aging, PowerRankings}

  @contending ["contender", "all-in"]
  @building ["rebuilding", "stuck"]

  @doc """
  Everything `gain/6` needs, read off a snapshot. `pick_values` is
  `%{{season, round} => value}`, the prices the trade finder used.
  """
  def context(snapshot, pick_values) do
    teams_by_roster = Map.new(snapshot.teams, &{&1.roster_id, &1})
    {now_values, now_source} = now_values(snapshot)
    positions = snapshot.league["roster_positions"]

    by_user =
      for roster <- snapshot.rosters, roster["owner_id"] != nil, into: %{} do
        team = teams_by_roster[roster["roster_id"]]
        {to_string(roster["owner_id"]), %{roster: roster, tier: team && team.tiers[:blend]}}
      end

    lineup = fn roster ->
      PowerRankings.best_lineup(roster, positions, snapshot.player_info, &now_values[&1])
    end

    lineup_total = &lineup.(&1).total

    future_value = fn id ->
      if Aging.past_cutoff?(snapshot.player_info[id]), do: 0, else: snapshot.ktc_values[id] || 0
    end

    rosters = snapshot.rosters

    %{
      by_user: by_user,
      roster_positions: positions,
      player_info: snapshot.player_info,
      now_values: now_values,
      now_source: now_source,
      future_value: future_value,
      pick_values: pick_values,
      mean_now: mean(Enum.map(rosters, lineup_total)),
      mean_future: mean(Enum.map(rosters, &sum(Enum.map(&1["players"] || [], future_value)))),
      lineup_total: lineup_total,
      # Who starts where under the win-now values, for callers that need the
      # lineup itself rather than its total (`TradeSearch`).
      lineup_starters: &Enum.filter(lineup.(&1).starters, fn s -> s.player_id end)
    }
  end

  # Projected points when the league was ranked on them, else KTC.
  defp now_values(snapshot) do
    case snapshot[:projected_points] do
      points when is_map(points) and map_size(points) > 0 -> {points, :proj}
      _ -> {snapshot.ktc_values, :ktc}
    end
  end

  @doc """
  One side's gain: `user_id` gives `give` and `give_picks`, gets `get` and
  `get_picks`. Returns `%{tier, gain, now, future, now_points}` - `now_points`
  is the raw change in the lineup's win-now total (projected points, or KTC
  without projections) - or nil for a user with no roster in the snapshot.
  A pick carrying its own `value` is priced at it; otherwise at
  `pick_values`.
  """
  def gain(context, user_id, give, get, give_picks, get_picks) do
    case context.by_user[to_string(user_id)] do
      nil ->
        nil

      %{roster: roster, tier: tier} ->
        players = roster["players"] || []
        after_trade = Map.put(roster, "players", (players -- give) ++ get)

        now_points = context.lineup_total.(after_trade) - context.lineup_total.(roster)
        now = share(now_points, context.mean_now)

        future =
          share(
            sum(Enum.map(get, context.future_value)) - sum(Enum.map(give, context.future_value)) +
              pick_total(get_picks, context) - pick_total(give_picks, context),
            context.mean_future
          )

        %{
          tier: tier,
          gain: blend(tier, now, future),
          now: now,
          future: future,
          now_points: now_points
        }
    end
  end

  defp blend(tier, now, _future) when tier in @contending, do: now
  defp blend(tier, _now, future) when tier in @building, do: future
  defp blend(_tier, now, future), do: (now + future) / 2

  defp pick_total(picks, context),
    do:
      sum(Enum.map(picks || [], &(&1[:value] || context.pick_values[{&1.season, &1.round}] || 0)))

  defp share(_delta, mean) when mean in [nil, 0, 0.0], do: 0.0
  defp share(delta, mean), do: delta / mean

  defp mean([]), do: nil
  defp mean(values), do: sum(values) / length(values)

  defp sum(values), do: Enum.reduce(values, 0, &(&2 + &1))
end
