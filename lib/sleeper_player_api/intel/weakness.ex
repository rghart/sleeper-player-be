defmodule SleeperPlayerApi.Intel.Weakness do
  @moduledoc """
  Where each team's starting lineup is thin or deep, position by position,
  against the rest of its league (docs/dynasty-engine.md, M2).

  `group_strength/2` is a port of `groupStrength` from my-sleeper-app's
  `src/lib/teamComparison.js`, which drew the "Starters vs you" bars, and is
  pinned to that function's output on the power-rankings fixtures. `analyze/1`
  builds the deficits and surpluses an agent asks about on top of it.

  Pure: it reads the teams `LeagueRankings` produced - their best lineup under
  each source - and nothing else.

  A group's strength is a z-score of the value a team starts there, one per
  source, so "thin at RB" means thin against these rosters, not against an
  absolute bar. Groups are read off the lineup's slots, so FLEX means "what
  this team starts in its flex slots", which is how a league actually plays:
  a team with three good RBs is not thin at RB just because one of them
  starts at FLEX.
  """

  @groups ["QB", "RB", "WR", "TE", "FLEX"]

  @group_of %{
    "QB" => "QB",
    "RB" => "RB",
    "WR" => "WR",
    "TE" => "TE",
    "FLEX" => "FLEX",
    "FLX" => "FLEX",
    "SUPER_FLEX" => "FLEX",
    "SFLX" => "FLEX",
    "WRRB_FLEX" => "FLEX",
    "REC_FLEX" => "FLEX"
  }

  @default_threshold 0.5

  alias SleeperPlayerApi.Intel.PowerRankings

  @doc "The position groups, in display order."
  def groups, do: @groups

  @doc "The position group a lineup slot belongs to, or nil for one that has none (K, DEF)."
  def group_of(slot), do: @group_of[slot]

  @doc """
  How far from the league average a group must be, in z, to count as a
  deficit or surplus. From config, default #{@default_threshold}.
  """
  def threshold do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:threshold, @default_threshold)
  end

  @doc """
  Each team's strength in every position group the league starts, as
  `%{roster_id => %{group => z}}`.

  `source` is a source id (`:ktc`, `:proj`, ...) or `:blend`, the mean of
  every source's z, as in the rankings.
  """
  def group_strength([], _source), do: %{}

  def group_strength([first | _] = teams, source) do
    source_ids = lineup_sources(first)
    used = if source == :blend, do: source_ids, else: Enum.filter(source_ids, &(&1 == source))

    groups =
      case used do
        [] -> []
        [lead | _] -> Enum.filter(@groups, &starts?(first.lineups[lead], &1))
      end

    empty = Map.new(teams, &{&1.roster_id, %{}})

    Enum.reduce(groups, empty, fn group, acc ->
      per_source = Enum.map(used, &PowerRankings.z_scores(totals(teams, &1, group)))

      teams
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {team, i}, acc ->
        z = Enum.reduce(per_source, 0, &(&2 + Enum.at(&1, i))) / length(per_source)
        Map.update!(acc, team.roster_id, &Map.put(&1, group, z))
      end)
    end)
  end

  @doc """
  Every team's groups, deficits first, as an agent or a screen reads them.

  Per team: `groups`, one per position group the league starts, each with the
  blended z, the z under every source, and the KeepTradeCut value the team
  starts there against the league median; then `deficits` (blended z at or
  below `-threshold`, weakest first) and `surpluses` (at or above
  `threshold`, strongest first), as group names.
  """
  def analyze(teams) do
    sources = if teams == [], do: [], else: lineup_sources(hd(teams))
    blend = group_strength(teams, :blend)
    by_source = Map.new(sources, &{&1, group_strength(teams, &1)})
    t = threshold()

    groups =
      case teams do
        [] -> []
        [first | _] -> Enum.filter(@groups, &Map.has_key?(blend[first.roster_id], &1))
      end

    ktc_medians =
      if :ktc in sources,
        do: Map.new(groups, &{&1, median(totals(teams, :ktc, &1))}),
        else: %{}

    Enum.map(teams, fn team ->
      rows =
        Enum.map(groups, fn group ->
          %{
            group: group,
            z: blend[team.roster_id][group],
            by_source: Map.new(sources, &{&1, by_source[&1][team.roster_id][group]}),
            ktc_value: if(:ktc in sources, do: group_total(team.lineups[:ktc], group)),
            league_median_ktc: ktc_medians[group]
          }
        end)

      %{
        roster_id: team.roster_id,
        name: team.name,
        tier: team.tiers[:blend],
        groups: rows,
        deficits:
          rows |> Enum.filter(&(&1.z <= -t)) |> Enum.sort_by(& &1.z) |> Enum.map(& &1.group),
        surpluses:
          rows |> Enum.filter(&(&1.z >= t)) |> Enum.sort_by(& &1.z, :desc) |> Enum.map(& &1.group)
      }
    end)
  end

  # Source ids in ranking order, so a blend adds them in the order the JS did.
  defp lineup_sources(team),
    do: Enum.filter([:proj, :adp, :ktc, :fc], &Map.has_key?(team.lineups, &1))

  defp starts?(nil, _group), do: false
  defp starts?(lineup, group), do: Enum.any?(lineup.starters, &(@group_of[&1.slot] == group))

  defp totals(teams, source, group), do: Enum.map(teams, &group_total(&1.lineups[source], group))

  defp group_total(nil, _group), do: 0

  defp group_total(lineup, group) do
    lineup.starters
    |> Enum.filter(&(@group_of[&1.slot] == group))
    |> Enum.reduce(0, &(&2 + &1.value))
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end
end
