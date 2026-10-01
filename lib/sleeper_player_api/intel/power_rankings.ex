defmodule SleeperPlayerApi.Intel.PowerRankings do
  @moduledoc """
  Dynasty power rankings: where every team in a league stands now, where it
  stands for the future, and the tier those two put it in.

  **A port, not a redesign.** This is the frontend's `src/lib/powerRankings.js`
  moved server-side (docs/dynasty-engine.md, M1), so the app and a later agent
  read one implementation instead of two. The golden fixtures in
  `test/support/fixtures/power_rankings/` were produced by the JavaScript and
  this module is correct when it reproduces them. The reasoning behind each
  rule is recorded in the JS file's comments and in the frontend's git history;
  the essentials are repeated here where they decide behaviour.

  Pure. `SleeperPlayerApi.Intel.LeagueRankings` assembles the inputs; nothing
  here knows where a value came from. A source is just a function from Sleeper
  player id to a number, so projections, ADP, KTC and FantasyCalc all plug in
  the same way, and a trained model can later join them unchanged.

  Both scores are league-relative z-scores: a "strong" lineup means strong
  against the other rosters in this league, not against an absolute bar.
  """

  alias SleeperPlayerApi.Intel.PickHoldings

  @tiers [
    %{id: "contender", label: "Contender", description: "Strong now, future intact"},
    %{id: "all-in", label: "All-in", description: "Strong now, future spent to get there"},
    %{id: "middle", label: "Middle", description: "Close to the league average for now"},
    %{
      id: "rebuilding",
      label: "Rebuilding",
      description: "Weak now, but has bought picks or has depth to build from"
    },
    %{id: "stuck", label: "Stuck", description: "Weak now, with no extra picks and thin depth"}
  ]

  # Where the tier lines sit, in standard deviations from the league average.
  # Provisional: chosen so a 12-team league puts roughly a third of its teams
  # on each side of "Middle". Overridable in config; these are the values the
  # frontend shipped with and the parity fixtures were captured under.
  @default_thresholds %{
    strong_now: 0.5,
    weak_now: -0.5,
    # A strong team is only All-in once its future is clearly below average;
    # a merely average future on a strong team is what a normal contender has.
    all_in_future: -0.5,
    # A weak team is Rebuilding when its future is at least average...
    rebuilding_future: 0,
    # ...or when it has bought picks on net: holds more pick value than its
    # own original picks are worth. Measured against the team's OWN picks, not
    # the league average, because once next season's picks are priced by
    # projected finish a bad team's own picks are early and worth more than
    # average, and an average-based test called every bad team a buyer.
    rebuilding_picks: 0
  }

  # Which real positions may fill each lineup slot. Covers Sleeper's flex
  # variants as well as the two the lineup screen shortens (FLX/SFLX): an
  # unrecognised slot would silently start nobody and understate every team in
  # the league by that slot.
  @slot_eligibility %{
    "FLEX" => ["RB", "WR", "TE"],
    "FLX" => ["RB", "WR", "TE"],
    "SUPER_FLEX" => ["QB", "RB", "WR", "TE"],
    "SFLX" => ["QB", "RB", "WR", "TE"],
    "WRRB_FLEX" => ["RB", "WR"],
    "REC_FLEX" => ["WR", "TE"]
  }

  @non_starting_slots ["BN", "IR", "TAXI"]

  # Sleeper statuses that mean a player cannot start however good he is.
  @unavailable ["IR", "PUP", "Sus"]

  @doc "The five tiers, in legend order. `id` is stable for code; `label` is for screens."
  def tiers, do: @tiers

  @doc "The tier thresholds in effect: the defaults, overridden by config."
  def thresholds do
    configured =
      :sleeper_player_api
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:thresholds, %{})

    Map.merge(@default_thresholds, configured)
  end

  @doc """
  The tier for a Now z-score, a Future z-score, and net pick value (nil when
  picks were not counted). Nil when either score is missing.
  """
  def tier_for(now, future, picks \\ nil)
  def tier_for(nil, _future, _picks), do: nil
  def tier_for(_now, nil, _picks), do: nil

  def tier_for(now, future, picks) do
    t = thresholds()

    cond do
      now >= t.strong_now ->
        if future >= t.all_in_future, do: "contender", else: "all-in"

      now <= t.weak_now ->
        bought_picks = picks != nil and picks > t.rebuilding_picks
        if future >= t.rebuilding_future or bought_picks, do: "rebuilding", else: "stuck"

      true ->
        "middle"
    end
  end

  @doc """
  The best legal starting lineup a roster can field under one source's values.

  Slots are filled most-restrictive first (dedicated positions, then narrow
  flexes, then superflex), each taking the most valuable eligible player left.
  Every flex here is a superset of the slots beneath it, so that order is
  optimal: a player only moves to a wider slot when every narrower one that
  wanted him is already full of someone better.

  Reserve and taxi players, and anyone Sleeper lists as unavailable, are left
  out. A player the source does not price is worth 0 to it, which costs every
  team the same slot.

  `roster` is Sleeper's roster map; `player_info` maps player id to a map with
  `"position"`, `"fantasy_positions"` and `"injury_status"`; `value_of` maps a
  player id to a number or nil.

  Returns `%{starters: [%{slot, index, player_id, value}], total}` with
  starters in league slot order.
  """
  def best_lineup(roster, roster_positions, player_info, value_of) do
    benched = MapSet.new((roster["reserve"] || []) ++ (roster["taxi"] || []))

    candidates =
      (roster["players"] || [])
      |> Enum.reject(&MapSet.member?(benched, &1))
      |> Enum.reject(&(get_in(player_info, [&1, "injury_status"]) in @unavailable))
      |> Enum.map(fn id ->
        %{id: id, positions: positions(player_info[id]), value: value_of.(id) || 0}
      end)
      # Stable, so equally valued players keep roster order, as in the JS.
      |> Enum.sort_by(& &1.value, :desc)

    slots =
      (roster_positions || [])
      |> Enum.reject(&(&1 in @non_starting_slots))
      |> Enum.with_index()
      |> Enum.map(fn {slot, index} ->
        %{slot: slot, index: index, eligible: eligible_for(slot)}
      end)
      # Stable, so equally narrow slots keep league order.
      |> Enum.sort_by(&{length(&1.eligible), &1.index})

    {starters, _used} =
      Enum.map_reduce(slots, MapSet.new(), fn %{slot: slot, index: index, eligible: eligible},
                                              used ->
        pick =
          Enum.find(candidates, fn player ->
            not MapSet.member?(used, player.id) and Enum.any?(player.positions, &(&1 in eligible))
          end)

        starter = %{
          slot: slot,
          index: index,
          player_id: pick && pick.id,
          value: if(pick, do: pick.value, else: 0)
        }

        {starter, if(pick, do: MapSet.put(used, pick.id), else: used)}
      end)

    starters = Enum.sort_by(starters, & &1.index)
    %{starters: starters, total: sum(Enum.map(starters, & &1.value))}
  end

  # `fantasy_positions` when Sleeper sends it, else the single `position`.
  # An empty list is an answer, not an absence, and is kept.
  defp positions(nil), do: []

  defp positions(info) do
    case info["fantasy_positions"] do
      nil -> Enum.reject([info["position"]], &is_nil/1)
      list -> list
    end
  end

  @doc "The positions that may fill a lineup slot."
  def eligible_for(slot), do: Map.get(@slot_eligibility, slot, [slot])

  @doc """
  Population z-scores. A league where every team scores the same has no
  spread to measure, so everyone is average (0) rather than NaN.
  """
  def z_scores([]), do: []

  def z_scores(values) do
    n = length(values)
    mean = sum(values) / n
    sd = :math.sqrt(sum(Enum.map(values, &((&1 - mean) ** 2))) / n)
    Enum.map(values, fn v -> if sd == 0, do: 0, else: (v - mean) / sd end)
  end

  @doc """
  Which rookie picks each roster holds, as `%{roster_id => [%{season, round,
  original_roster_id}]}`.

  Every roster starts owning its own pick in every round of every season;
  Sleeper's league-level `traded_picks` lists only the ones that moved.
  `roster_id` on a traded pick is the ORIGINAL team and `owner_id` the current
  one, both roster ids despite the name.

  Picks are listed season, then round, then original roster in `roster_ids`
  order. `PickHoldings.build/4` answers the same question for the trade
  finder but drops the original roster, which pick pricing needs; folding the
  two together is a follow-up once this port is pinned.
  """
  def owned_picks(roster_ids, traded_picks, seasons, rounds) do
    keys =
      for season <- seasons,
          round <- rounds_range(rounds),
          roster_id <- roster_ids,
          do: {season, round, roster_id}

    known = MapSet.new(keys)

    overrides =
      Enum.reduce(traded_picks || [], %{}, fn traded, acc ->
        key = {PickHoldings.to_season(traded["season"]), traded["round"], traded["roster_id"]}
        if MapSet.member?(known, key), do: Map.put(acc, key, traded["owner_id"]), else: acc
      end)

    empty = Map.new(roster_ids, &{&1, []})

    keys
    |> Enum.reverse()
    |> Enum.reduce(empty, fn {season, round, original} = key, acc ->
      owner = Map.get(overrides, key, original)
      pick = %{season: season, round: round, original_roster_id: original}
      if Map.has_key?(acc, owner), do: Map.update!(acc, owner, &[pick | &1]), else: acc
    end)
  end

  # `1..0` counts down in Elixir; a league with no rookie rounds has no picks.
  defp rounds_range(rounds) when is_integer(rounds) and rounds >= 1, do: 1..rounds
  defp rounds_range(_), do: []

  @doc """
  Rank every roster in a league.

  `sources` is an ordered list of `{source_id, value_of}` for the Now scores.
  `future` is the dynasty value function for the Future score, which counts
  everything a roster owns OUTSIDE its best lineup under that source: bench,
  taxi and reserve players, plus owned picks priced by `picks.value_of`.

  Starters are left out of Future on purpose, and it was measured: counting
  the whole roster made Future track Now so closely (correlation 0.5-0.8
  across five real leagues) that almost every weak team read as Stuck and
  almost no strong one as All-in. Without them the scores are close to
  independent and all five tiers occur.

  `picks` is nil (picks not counted) or `%{traded_picks, seasons, rounds,
  value_of}`, where `value_of` returns a number or `%{value, basis, tier}`.

  Returns one map per roster, in roster order, with raw totals as well as
  z-scores so a caller can show its working.
  """
  def rank_teams(
        %{rosters: rosters, roster_positions: positions, player_info: info, sources: sources} =
          args
      ) do
    future = args.future
    picks = args[:picks]
    source_ids = Enum.map(sources, &elem(&1, 0))

    lineups =
      Enum.map(rosters, fn roster ->
        Map.new(sources, fn {id, value_of} ->
          {id, best_lineup(roster, positions, info, value_of)}
        end)
      end)

    holdings =
      if picks,
        do:
          owned_picks(
            Enum.map(rosters, & &1["roster_id"]),
            picks.traded_picks,
            picks.seasons,
            picks.rounds
          ),
        else: %{}

    future_totals =
      Enum.map(rosters, fn roster ->
        starters =
          best_lineup(roster, positions, info, future).starters |> MapSet.new(& &1.player_id)

        player_value =
          (roster["players"] || [])
          |> Enum.reject(&MapSet.member?(starters, &1))
          |> Enum.map(&(future.(&1) || 0))
          |> sum()

        held =
          holdings
          |> Map.get(roster["roster_id"], [])
          |> Enum.map(fn pick ->
            case picks.value_of.(pick) do
              %{} = priced -> pick |> Map.merge(priced) |> Map.put(:value, priced[:value] || 0)
              value -> Map.put(pick, :value, value || 0)
            end
          end)

        %{player_value: player_value, pick_value: sum(Enum.map(held, & &1.value)), picks: held}
      end)

    # What each team's OWN original picks are worth, wherever they now sit.
    # Future counts pick capital beyond that allotment, so holding your own
    # picks is neutral and a bad team's own early picks don't read as a haul.
    own_picks_value =
      for detail <- future_totals,
          pick <- detail.picks,
          reduce: Map.new(rosters, &{&1["roster_id"], 0}) do
        acc ->
          if Map.has_key?(acc, pick.original_roster_id),
            do: Map.update!(acc, pick.original_roster_id, &(&1 + pick.value)),
            else: acc
      end

    future_totals =
      rosters
      |> Enum.zip(future_totals)
      |> Enum.map(fn {roster, detail} ->
        net = if picks, do: detail.pick_value - own_picks_value[roster["roster_id"]], else: 0
        Map.merge(detail, %{net_pick_value: net, total: detail.player_value + net})
      end)

    now_z =
      Map.new(source_ids, fn id ->
        {id, z_scores(Enum.map(lineups, &get_in(&1, [id, :total])))}
      end)

    future_z = z_scores(Enum.map(future_totals, & &1.total))
    net_picks = Enum.map(future_totals, fn f -> if picks, do: f.net_pick_value end)

    [rosters, lineups, future_totals, future_z, net_picks]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.map(fn {{roster, lineup, detail, future_score, net}, i} ->
      by_source = Map.new(source_ids, &{&1, Enum.at(now_z[&1], i)})

      # The blend is the mean of the sources' z-scores, not a z-score of summed
      # raw totals: the sources live on different scales (points, KTC's 0-10k,
      # FantasyCalc's 0-11k), and summing first would let the biggest decide.
      blend =
        if source_ids == [],
          do: nil,
          else: sum(Enum.map(source_ids, &by_source[&1])) / length(source_ids)

      now = Map.put(by_source, :blend, blend)

      %{
        roster_id: roster["roster_id"],
        owner_id: roster["owner_id"],
        name: roster["manager_display_name"],
        now: now,
        future: future_score,
        picks: net,
        tiers: Map.new(now, fn {id, z} -> {id, tier_for(z, future_score, net)} end),
        lineups: lineup,
        future_detail: detail
      }
    end)
  end

  @doc """
  The rookie-draft seasons whose picks still count as future assets.

  A season's picks stop being picks once its draft has run. So this season
  counts only while its draft is still to come, and only seasons the value
  source prices are kept: an unpriced pick would count as 0 for every team,
  and a guessed price would be a number made up for the screen.
  """
  def pick_seasons_in_scope(priced_seasons, league_season, current_draft_complete) do
    season = PickHoldings.to_season(league_season)

    (priced_seasons || [])
    |> Enum.map(&PickHoldings.to_season/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 > season or (&1 == season and not current_draft_complete)))
    |> Enum.sort()
  end

  @doc "1-based rank of each team by a score, best first, as `%{roster_id => rank}`."
  def ranks_by(teams, score) do
    teams
    |> Enum.sort_by(&score.(&1), &desc_nil_last/2)
    |> Enum.with_index(1)
    |> Map.new(fn {team, rank} -> {team.roster_id, rank} end)
  end

  # Nil sorts last, as the JS's `?? -Infinity` does; ties keep their order.
  defp desc_nil_last(nil, nil), do: true
  defp desc_nil_last(nil, _), do: false
  defp desc_nil_last(_, nil), do: true
  defp desc_nil_last(a, b), do: a >= b

  # Left to right, like the JS `reduce`, so float totals match it.
  defp sum(values), do: Enum.reduce(values, 0, &(&2 + &1))
end
