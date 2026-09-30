defmodule SleeperPlayerApi.Intel.PickSlots do
  @moduledoc """
  Where a rookie pick will land, as well as can honestly be said.

  Ported from the frontend's `src/lib/pickSlots.js` alongside
  `SleeperPlayerApi.Intel.PowerRankings`, and pinned by the same fixtures.

  A pick's value depends on its slot, and its slot depends on where its
  ORIGINAL team finishes: a Stuck team's 1st is probably early, a Contender's
  probably late. The most precise answer available wins:

    1. The draft order is set: the exact slot.
    2. The regular season is over: the slot the final standings imply.
    3. Otherwise: early / mid / late, from a projected finish.

  ...and only for the next draft. A pick two drafts out is a guess about a
  season nobody has played; those stay "mid".

  Pure: `LeagueRankings` hands in the teams it has already scored for Now.
  """

  alias SleeperPlayerApi.Intel.PowerRankings

  defp games_played(roster) do
    settings = (roster && roster["settings"]) || %{}
    (settings["wins"] || 0) + (settings["losses"] || 0) + (settings["ties"] || 0)
  end

  defp points_for(roster) do
    settings = (roster && roster["settings"]) || %{}
    (settings["fpts"] || 0) + (settings["fpts_decimal"] || 0) / 100
  end

  @doc """
  How far through the regular season the league is, 0 to 1: games played by
  the team that has played most, over the weeks before the playoffs.
  """
  def season_progress(rosters, league) do
    playoff_start = get_in(league || %{}, ["settings", "playoff_week_start"]) || 15
    regular_weeks = max(1, playoff_start - 1)
    played = Enum.reduce(rosters || [], 0, &max(games_played(&1), &2))
    min(1, played / regular_weeks)
  end

  @doc """
  Each roster's projected finish, 1 = best, as `%{roster_id => finish}`.

  Early on it is the Now blend; as the season goes, results take over in
  proportion to how much of it has been played. Results means points per game
  rather than wins: points predict the final table better than a record and
  do not swing on one close week.
  """
  def projected_finish(teams, rosters, league) do
    weight = season_progress(rosters, league)
    by_id = Map.new(rosters || [], &{&1["roster_id"], &1})

    rate =
      Enum.map(teams, fn team ->
        roster = by_id[team.roster_id]
        games = games_played(roster)
        if games > 0, do: points_for(roster) / games, else: 0
      end)

    teams
    |> Enum.zip(PowerRankings.z_scores(rate))
    |> Enum.map(fn {team, rate_z} ->
      %{roster_id: team.roster_id, score: (1 - weight) * (team.now.blend || 0) + weight * rate_z}
    end)
    # Stable, so tied teams keep roster order, as in the JS.
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.with_index(1)
    |> Map.new(fn {entry, finish} -> {entry.roster_id, finish} end)
  end

  @doc "Early / mid / late from a finish: the bottom third picks early, the top third late."
  def tier_for_finish(finish, team_count) when is_nil(finish) or team_count in [nil, 0], do: "mid"

  def tier_for_finish(finish, team_count) do
    third = team_count / 3

    cond do
      finish > team_count - third -> "early"
      finish <= third -> "late"
      true -> "mid"
    end
  end

  @doc """
  The slot each roster holds in a draft whose order is set, as
  `%{roster_id => slot}`. Sleeper keys `draft_order` by USER id, so it goes
  through the rosters' owners. Empty when the order is not set.
  """
  def draft_slots(draft, rosters) do
    case draft && draft["draft_order"] do
      order when is_map(order) ->
        Enum.reduce(rosters || [], %{}, fn roster, slots ->
          case Map.get(order, roster["owner_id"]) do
            nil -> slots
            slot -> Map.put(slots, roster["roster_id"], slot)
          end
        end)

      _ ->
        %{}
    end
  end

  @doc """
  A slot within a given round. In a snake draft the even rounds run
  backwards, so the team picking 1st in round 1 picks last in round 2.
  """
  def slot_in_round(slot, round, team_count, snake) do
    if snake and rem(round, 2) == 0, do: team_count + 1 - slot, else: slot
  end

  @doc """
  Prices one pick and says how: `%{value, basis, tier}`.

  `basis` is `"slot"` (the draft order), `"standings"` (the season is over),
  `"projected"` (early/mid/late from a projected finish) or `"mid"` (a pick
  too far out to place). `tier` is what was priced: `"early"`, `"slot-4"`.

  `price_of` looks a tier up for the pick's season and round and returns nil
  when the source does not price it, in which case this falls back a step: an
  exact slot the source has not listed is still worth its early/mid/late
  estimate.

  `context` carries `next_season`, `finish` (from `projected_finish/3`),
  `team_count`, `slots` (from `draft_slots/2`), `draft` and `season_over`.
  """
  def price_pick(pick, context, price_of) do
    mid = fn -> %{value: price_of.("mid"), basis: "mid", tier: "mid"} end

    if pick.season != context.next_season do
      mid.()
    else
      snake = context.draft != nil and context.draft["type"] == "snake"
      original = pick.original_roster_id
      exact_slot = Map.get(context.slots || %{}, original)

      standings_slot =
        if context.season_over and Map.has_key?(context.finish, original),
          do: context.team_count + 1 - context.finish[original]

      exact =
        Enum.find_value([{exact_slot, "slot"}, {standings_slot, "standings"}], fn
          {nil, _basis} ->
            nil

          {slot, basis} ->
            tier = "slot-#{slot_in_round(slot, pick.round, context.team_count, snake)}"
            if value = price_of.(tier), do: %{value: value, basis: basis, tier: tier}
        end)

      exact || projected(pick, context, price_of) || mid.()
    end
  end

  defp projected(pick, context, price_of) do
    tier = tier_for_finish(context.finish[pick.original_roster_id], context.team_count)
    if value = price_of.(tier), do: %{value: value, basis: "projected", tier: tier}
  end
end
