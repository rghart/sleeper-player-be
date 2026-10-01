defmodule SleeperPlayerApi.Intel.TradeSearch do
  @moduledoc """
  Trade ideas for one manager, searched by roster quality and judged by what
  each side gains in its window (docs/dynasty-engine.md, M4). The successor
  to `TradeFinder`, which matched on body counts; served at
  `/leagues/:id/trade-ideas` while `/trades` keeps the old finder for the app.

  **Every idea is even on market value.** KeepTradeCut, on the league's TE
  premium tier, through `TradeValue`'s package adjustment, within
  `fair_band`. That is what makes a trade one the other manager could
  accept, and it is why picks can balance a trade whatever the windows: a
  pick is worth something on the market even when it scores nothing this
  season.

  **When a package is not even, the side ahead adds to it**: picks or bench
  players, from either side whatever its window, as many as it takes but
  worth no more than `max_added_share` of the larger side. Each addition is
  the piece that leaves the smallest gap.

  **No trade size limit.** A beam search grows packages one player at a time
  from every 1-for-1, keeping the most promising `beam_width` each round, and
  stops when a round stops improving or after `max_evaluations_per_partner`
  packages: a bound on the work, not on the trade. A side that would end up
  over its roster limit cuts its lowest-valued bench players to make room,
  and those cuts count against it and are reported.

  **Projections decide what to suggest, by mode:**

    * `"window"` (default): both sides gain in their own window
      (`TradeWindow`): a contender its lineup now, a rebuilder its future.
      Ranked by the smaller of the two gains.
    * `"win_now"`: your projected lineup improves this season, and the
      partner does not lose in its window. Ranked by your lineup gain.
    * `"market"`: the partner does not lose in its window. Ranked by the
      market value you come out ahead.

  **Candidates are chosen by quality, not counts.** You offer players who
  do not start for you, or who start in a group where you are strong
  (`Weakness`): a third tight end playing flex is a surplus even though
  five tight ends is an average count. You ask for their players at the
  positions where you are thin, on the same terms from their side.

  Pure. The controller builds `context/4` from a `LeagueSnapshot`.
  """

  alias SleeperPlayerApi.Intel.{TradeValue, TradeWindow, Weakness}

  @modes ~w(window win_now market)
  @flex_positions ["RB", "WR", "TE"]
  @tradeable ["QB", "RB", "WR", "TE"]

  defp config(key, default) do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp settings do
    %{
      fair_band: config(:fair_band, 0.12),
      max_added_share: config(:max_added_share, 0.35),
      beam_width: config(:beam_width, 12),
      max_evaluations: config(:max_evaluations_per_partner, 400),
      candidates: config(:candidates_per_side, 8),
      surplus_z: config(:surplus_z, 0.5),
      need_z: config(:need_z, -0.25),
      per_partner: config(:per_partner, 3),
      limit: config(:limit, 15)
    }
  end

  @doc "The modes, default first."
  def modes, do: @modes

  @doc """
  Everything the search needs, read off a snapshot once. `window` is
  `TradeWindow.context/2`'s output.
  """
  def context(snapshot, window) do
    weakness = Map.new(Weakness.analyze(snapshot.teams), &{&1.roster_id, &1})

    teams =
      for roster <- snapshot.rosters, roster["owner_id"] != nil, into: %{} do
        team = Enum.find(snapshot.teams, &(&1.roster_id == roster["roster_id"]))
        groups = Map.new(weakness[roster["roster_id"]].groups, &{&1.group, &1.z})
        now_lineup = window.lineup_starters.(roster)

        {to_string(roster["owner_id"]),
         %{
           user_id: to_string(roster["owner_id"]),
           name: team.name,
           roster: roster,
           groups: groups,
           # Slot each player starts in under the win-now lineup, if any.
           starting: Map.new(now_lineup, &{&1.player_id, &1.slot}),
           picks:
             Enum.map(team.future_detail.picks, &Map.take(&1, [:season, :round, :value, :tier]))
         }}
      end

    values = snapshot.ktc_values

    %{
      teams: teams,
      values: values,
      # Active roster spots: every slot in `roster_positions`, bench included.
      # Taxi and reserve are separate in Sleeper and do not count.
      capacity: length(snapshot.league["roster_positions"] || []),
      positions: Map.new(snapshot.player_info, fn {id, info} -> {id, info["position"]} end),
      top_value: values |> Map.values() |> Enum.max(fn -> 0 end),
      window: window
    }
  end

  @doc """
  Ideas for `user_id` in `mode`, best first. Returns `{:ok, ideas}` or
  `{:error, :not_in_league}` / `{:error, {:invalid_mode, mode}}`.
  """
  def ideas(context, user_id, mode \\ "window")

  def ideas(_context, _user_id, mode) when mode not in @modes,
    do: {:error, {:invalid_mode, mode}}

  def ideas(context, user_id, mode) do
    case context.teams[to_string(user_id)] do
      nil ->
        {:error, :not_in_league}

      me ->
        s = settings()

        ideas =
          context.teams
          |> Map.values()
          |> Enum.reject(&(&1.user_id == me.user_id))
          |> Enum.flat_map(fn partner ->
            me
            |> against(partner, mode, context, s)
            |> Enum.take(s.per_partner)
          end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(s.limit)

        {:ok, ideas}
    end
  end

  # A beam search over packages. Every 1-for-1 between my spare players and
  # their wanted ones is a seed; each round grows the most promising packages
  # by one player on either side and keeps the best `beam_width`. There is no
  # cap on a trade's size: it stops when a round stops improving, the
  # candidates run out, or `max_evaluations` packages have been judged, which
  # bounds the work rather than the trade.
  defp against(me, partner, mode, context, s) do
    give = spare(me, context, s) |> Enum.take(s.candidates)
    get = wanted(partner, me, context, s) |> Enum.take(s.candidates)
    seeds = for a <- give, b <- get, do: {[a], [b]}

    {ideas, _seen, _n} =
      beam(seeds, {give, get}, {me, partner, mode, context, s}, {[], MapSet.new(), 0}, nil)

    ideas
    |> Enum.sort_by(& &1.score, :desc)
    # One idea per set of players you ask for: the same target offered for
    # three different packages is one idea, not three.
    |> Enum.uniq_by(&Enum.sort(&1.get))
  end

  defp beam([], _pools, _env, acc, _best), do: acc

  defp beam(
         frontier,
         {give_pool, get_pool} = pools,
         {_, _, _, _, s} = env,
         {ideas, seen, n},
         best
       ) do
    {judged, {ideas, seen, n}} =
      Enum.flat_map_reduce(frontier, {ideas, seen, n}, fn package, {ideas, seen, n} ->
        key = normalize(package)

        cond do
          MapSet.member?(seen, key) or n >= s.max_evaluations ->
            {[], {ideas, seen, n}}

          true ->
            {potential, idea} = judge(package, env)
            ideas = if idea, do: [idea | ideas], else: ideas
            {[{potential, package}], {ideas, MapSet.put(seen, key), n + 1}}
        end
      end)

    kept = judged |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.take(s.beam_width)
    round_best = kept |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> nil end)

    if round_best == nil or (best != nil and round_best <= best) or n >= s.max_evaluations do
      {ideas, seen, n}
    else
      children =
        for {_potential, {g, t}} <- kept,
            child <-
              Enum.map(give_pool -- g, &{g ++ [&1], t}) ++
                Enum.map(get_pool -- t, &{g, t ++ [&1]}),
            do: child

      beam(children, pools, env, {ideas, seen, n}, round_best)
    end
  end

  defp normalize({g, t}), do: {Enum.sort(g), Enum.sort(t)}

  # Players a team could move: priced, tradeable, and either not starting or
  # starting in a group where the team is strong. Most valuable first.
  defp spare(team, context, s) do
    (team.roster["players"] || [])
    |> Enum.filter(&tradeable?(&1, context))
    |> Enum.filter(fn id ->
      case team.starting[id] do
        nil -> true
        slot -> (team.groups[Weakness.group_of(slot)] || 0) >= s.surplus_z
      end
    end)
    |> by_value(context)
  end

  # Their spare players at a position where I am thin.
  defp wanted(partner, me, context, s) do
    partner
    |> spare(context, s)
    |> Enum.filter(&needed?(me, context.positions[&1], s))
  end

  defp needed?(me, position, s) do
    own = me.groups[position]
    flex = if position in @flex_positions, do: me.groups["FLEX"]
    Enum.any?([own, flex], &(is_number(&1) and &1 <= s.need_z))
  end

  defp tradeable?(id, context),
    do: context.positions[id] in @tradeable and is_number(context.values[id])

  defp by_value(ids, context), do: Enum.sort_by(ids, &(-context.values[&1]))

  # One package: how promising it is (to steer the search), and the idea it
  # makes once evened on market value, if it can be and it passes the mode.
  # Windows are measured on the evened trade, including the players a side
  # must cut to make room.
  defp judge({give, get}, {me, partner, mode, context, s}) do
    raw_mine = gain(context, me, give, get, [], [])
    raw_theirs = gain(context, partner, get, give, [], [])
    potential = potential(mode, raw_mine, raw_theirs, trade(give, get, [], [], context))

    idea =
      with {:ok, trade} <- balance(give, get, me, partner, context, s),
           my_cuts = cuts(me, trade.give, trade.get, context),
           their_cuts = cuts(partner, trade.get, trade.give, context),
           mine when mine != nil <-
             gain(
               context,
               me,
               trade.give ++ my_cuts,
               trade.get,
               trade.give_picks,
               trade.get_picks
             ),
           theirs when theirs != nil <-
             gain(
               context,
               partner,
               trade.get ++ their_cuts,
               trade.give,
               trade.get_picks,
               trade.give_picks
             ),
           {:ok, score} <- score(mode, mine, theirs, trade) do
        Map.merge(trade, %{
          partner_id: partner.user_id,
          partner_name: partner.name,
          mode: mode,
          score: score,
          my_window: mine,
          their_window: theirs,
          my_cuts: my_cuts,
          their_cuts: their_cuts
        })
      else
        _ -> nil
      end

    {potential || -1.0e9, idea}
  end

  defp score("window", mine, theirs, _trade) do
    if mine.gain > 0 and theirs.gain > 0, do: {:ok, min(mine.gain, theirs.gain)}, else: :reject
  end

  defp score("win_now", mine, theirs, _trade) do
    if mine.now > 0 and theirs.gain >= 0, do: {:ok, mine.now}, else: :reject
  end

  defp score("market", _mine, theirs, trade) do
    # Positive when I take in more adjusted value than I send.
    edge = trade.get_value - trade.give_value
    if theirs.gain >= 0 and edge > 0, do: {:ok, edge / max(trade.give_value, 1)}, else: :reject
  end

  defp gain(context, team, give, get, give_picks, get_picks),
    do: TradeWindow.gain(context.window, team.user_id, give, get, give_picks, get_picks)

  # The mode's objective on the package as proposed, before evening: what the
  # beam keeps growing. A side that would lose in its window pulls it down.
  defp potential(_mode, nil, _theirs, _trade), do: nil
  defp potential(_mode, _mine, nil, _trade), do: nil
  defp potential("window", mine, theirs, _trade), do: min(mine.gain, theirs.gain)

  defp potential("win_now", mine, theirs, _trade), do: min_if(mine.now, theirs.gain)

  defp potential("market", _mine, theirs, trade),
    do: ((trade.get_value - trade.give_value) / max(trade.give_value, 1)) |> min_if(theirs.gain)

  # A negative partner gain caps the potential, so the beam steers away from
  # packages the other side would refuse.
  defp min_if(value, other) when other < 0, do: min(value, other)
  defp min_if(value, _other), do: value

  # The players a team must cut to fit what it receives: the lowest-valued
  # players outside its lineup, beyond the open spots on its active roster
  # (taxi and reserve do not count against it).
  defp cuts(team, outgoing, incoming, context) do
    roster = team.roster
    benched = (roster["reserve"] || []) ++ (roster["taxi"] || [])
    active = length((roster["players"] || []) -- benched)
    over = active - length(outgoing) + length(incoming) - context.capacity

    if over > 0 do
      ((roster["players"] || []) -- (benched ++ outgoing))
      |> Enum.reject(&Map.has_key?(team.starting, &1))
      |> Enum.sort_by(&(context.values[&1] || 0))
      |> Enum.take(over)
    else
      []
    end
  end

  # Even as it stands, or evened by the side ahead adding pieces until it is:
  # each step adds whichever of its picks or bench players leaves the
  # smallest gap, with no limit on how many, only on how much
  # (`max_added_share` of the larger side's raw value).
  defp balance(give, get, me, partner, context, s) do
    base = trade(give, get, [], [], context)

    cond do
      fair?(base, s) ->
        {:ok, base}

      # I take in more, so I add.
      base.get_value > base.give_value ->
        add(base, me, :give, give ++ get, context, s)

      true ->
        add(base, partner, :get, give ++ get, context, s)
    end
  end

  defp add(base, team, side, in_trade, context, s) do
    cap = s.max_added_share * max(base.give_raw, base.get_raw)

    pool =
      Enum.map(team.picks, &{:pick, &1, &1.value}) ++
        (((team.roster["players"] || []) -- in_trade)
         |> Enum.reject(&Map.has_key?(team.starting, &1))
         |> Enum.filter(&tradeable?(&1, context))
         |> Enum.map(&{:player, &1, context.values[&1]}))

    pool = Enum.filter(pool, fn {_, _, v} -> is_number(v) and v > 0 and v <= cap end)
    grow(base, side, [], pool, cap, context, s)
  end

  defp grow(trade, side, combo, pool, cap, context, s) do
    spent = Enum.reduce(combo, 0, fn {_, _, v}, acc -> acc + v end)
    gap = abs(trade.get_value - trade.give_value)

    best =
      pool
      |> Enum.filter(fn {_, _, v} -> spent + v <= cap end)
      |> Enum.map(fn piece -> {piece, with_added(trade, side, [piece], context)} end)
      |> Enum.min_by(fn {_piece, t} -> abs(t.get_value - t.give_value) end, fn -> nil end)

    case best do
      nil ->
        :uneven

      {piece, next} ->
        combo = combo ++ [piece]

        cond do
          fair?(next, s) -> {:ok, Map.put(next, :added, added(side, combo))}
          abs(next.get_value - next.give_value) >= gap -> :uneven
          true -> grow(next, side, combo, pool -- [piece], cap, context, s)
        end
    end
  end

  defp with_added(base, side, combo, context) do
    players = for {:player, id, _} <- combo, do: id
    picks = for {:pick, pick, _} <- combo, do: pick

    case side do
      :give ->
        trade(base.give ++ players, base.get, base.give_picks ++ picks, base.get_picks, context)

      :get ->
        trade(base.give, base.get ++ players, base.give_picks, base.get_picks ++ picks, context)
    end
  end

  defp added(side, combo) do
    %{
      side: side,
      players: for({:player, id, _} <- combo, do: id),
      picks: for({:pick, pick, _} <- combo, do: pick)
    }
  end

  defp trade(give, get, give_picks, get_picks, context) do
    give_values = Enum.map(give, &context.values[&1]) ++ Enum.map(give_picks, & &1.value)
    get_values = Enum.map(get, &context.values[&1]) ++ Enum.map(get_picks, & &1.value)
    evaluation = TradeValue.evaluate(give_values, get_values, context.top_value)

    %{
      give: give,
      get: get,
      give_picks: give_picks,
      get_picks: get_picks,
      give_value: evaluation.one.adjusted,
      get_value: evaluation.two.adjusted,
      give_raw: evaluation.one.raw,
      get_raw: evaluation.two.raw,
      added: nil
    }
  end

  defp fair?(%{give_value: a, get_value: b}, s) do
    larger = max(a, b)
    larger > 0 and abs(a - b) / larger <= s.fair_band
  end
end
