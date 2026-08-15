defmodule SleeperPlayerApi.Intel.TradeFinder do
  @moduledoc """
  Trades that two rosters might actually both want.

  A fair trade and a *wanted* trade are different things, and conflating them
  is what makes most trade tools useless. Value-neutral swaps are everywhere —
  any two players priced the same "work" — so a finder that ranks on fairness
  alone returns thousands of suggestions nobody would send. What makes a trade
  wanted is that each side gives from a surplus and gets at a need.

  So a suggestion has to clear two independent bars:

    1. **Fairness** — the two sides are within `@fair_band` of each other once
       `TradeValue` has adjusted them, so a package of spare parts cannot pass
       by out-summing one good player.
    2. **Fit** — each side gives at a position it is deep in and gets at one
       it is thin in. Both sides, not just the asking one; a trade only your
       side wants is a trade that does not happen.

  **What this does not claim.** It says two rosters fit, with the numbers that
  say so. It does not say a trade is good for you, because that depends on
  whether you are contending — which nothing here knows. Same rule the
  survival number follows: state the measurement, let the manager decide.

  **The need model is the weakest part and is deliberately crude.** It counts
  bodies against dedicated starting slots and does not run a lineup
  optimiser, so FLEX is not modelled (a flex slot could be filled from three
  positions, and deciding which is a different problem). SUPER_FLEX *is*
  counted, as a quarterback slot, matching what the frontend's
  `leagueMarketSettings` already does. The surplus signal is coarse but
  robust: a manager with five running backs and two starting slots is deep at
  running back under any flex interpretation.
  """

  alias SleeperPlayerApi.Intel.TradeValue

  # How far apart two adjusted sides may be and still be worth proposing, as
  # a share of the larger side. Wide enough that a real trade with a small
  # sweetener survives, tight enough to exclude a fleecing.
  @fair_band 0.12

  # A roster is deep at a position when it holds more than its starters plus
  # one — the plus one being the backup nobody trades. Thin is at or below
  # the starting requirement.
  @depth_cushion 1

  # Positions worth trading. Kickers and defences are not dynasty assets and
  # KTC does not price them.
  @tradeable ~w(QB RB WR TE)

  @type roster :: %{
          user_id: integer | String.t(),
          display_name: String.t() | nil,
          player_ids: [String.t()]
        }

  @doc """
  Suggestions between one roster and every other roster given.

  `positions` and `values` are lookups keyed by player id (string), and
  `starters` is `%{"RB" => 2, ...}` derived from the league's
  `roster_positions`. `top_value` is the board's most valuable asset, which
  sets `TradeValue`'s scale.

  Returns suggestions ranked best-fit first, capped per partner so one
  well-matched roster cannot fill the whole list.
  """
  @spec find(roster, [roster], map) :: [map]
  def find(mine, others, opts) do
    per_partner = Map.get(opts, :per_partner, 3)
    my_depth = depth(mine.player_ids, opts)

    others
    |> Enum.flat_map(fn theirs ->
      mine
      |> suggestions_against(theirs, my_depth, opts)
      |> Enum.take(per_partner)
    end)
    |> Enum.sort_by(& &1.fit, :desc)
  end

  defp suggestions_against(mine, theirs, my_depth, opts) do
    their_depth = depth(theirs.player_ids, opts)

    # Only assets each side would plausibly move: theirs from their surplus,
    # mine from mine. Enumerating the full cross product would be 900 pairs
    # of players nobody is offering.
    my_spare = spare(mine.player_ids, my_depth, opts)
    their_spare = spare(theirs.player_ids, their_depth, opts)

    pairs =
      one_for_one(my_spare, their_spare) ++
        two_for_one(my_spare, their_spare) ++
        two_for_one(their_spare, my_spare, :flip)

    pairs
    |> Enum.flat_map(&score(&1, theirs, my_depth, their_depth, opts))
    |> Enum.sort_by(& &1.fit, :desc)
  end

  defp one_for_one(mine, theirs), do: for(a <- mine, b <- theirs, do: {[a], [b]})

  # Two of one side's spare parts for one of the other's better assets — the
  # shape most real dynasty trades take. Capped by only pairing within a side,
  # which keeps this quadratic in one roster rather than cubic across both.
  defp two_for_one(from, to, flip \\ nil) do
    combos = for [a, b] <- combinations(from, 2), c <- to, do: {[a, b], [c]}
    if flip == :flip, do: Enum.map(combos, fn {x, y} -> {y, x} end), else: combos
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _n), do: []

  defp combinations([head | tail], n) do
    Enum.map(combinations(tail, n - 1), &[head | &1]) ++ combinations(tail, n)
  end

  # One candidate trade, scored — or `[]` if it fails either bar.
  defp score({give, get}, theirs, my_depth, their_depth, opts) do
    give_values = Enum.map(give, &value(&1, opts))
    get_values = Enum.map(get, &value(&1, opts))

    with true <- Enum.all?(give_values ++ get_values, &is_number/1),
         evaluation = TradeValue.evaluate(give_values, get_values, opts.top_value),
         true <- fair?(evaluation),
         my_fit = fit_for(give, get, my_depth, opts),
         their_fit = fit_for(get, give, their_depth, opts),
         # Both sides, not just the asking one. A trade only you want is a
         # trade that does not happen.
         true <- my_fit > 0 and their_fit > 0 do
      [
        %{
          partner_id: to_string(theirs.user_id),
          partner_name: theirs.display_name,
          give: give,
          get: get,
          give_value: evaluation.one.adjusted,
          get_value: evaluation.two.adjusted,
          raw_gap: evaluation.raw_gap,
          adjusted_gap: evaluation.adjusted_gap,
          my_fit: my_fit,
          their_fit: their_fit,
          fit: my_fit + their_fit
        }
      ]
    else
      _ -> []
    end
  end

  defp fair?(%{one: %{adjusted: a}, two: %{adjusted: b}}) do
    larger = max(a, b)
    larger > 0 and abs(a - b) / larger <= @fair_band
  end

  @doc """
  How many bodies a roster holds at each tradeable position.

  Public for the tests, and for a caller that wants to show the shape it
  matched on rather than only the verdict.
  """
  @spec depth([String.t()], map) :: %{String.t() => integer}
  def depth(player_ids, opts) do
    player_ids
    |> Enum.map(&position(&1, opts))
    |> Enum.filter(&(&1 in @tradeable))
    |> Enum.frequencies()
  end

  # The players a roster could move without touching its starters.
  defp spare(player_ids, depth, opts) do
    Enum.filter(player_ids, fn id ->
      pos = position(id, opts)
      pos in @tradeable and deep?(depth, pos, opts) and is_number(value(id, opts))
    end)
  end

  defp deep?(depth, position, opts) do
    Map.get(depth, position, 0) > required(position, opts) + @depth_cushion
  end

  defp thin?(depth, position, opts) do
    Map.get(depth, position, 0) <= required(position, opts)
  end

  defp required(position, opts), do: Map.get(opts.starters, position, 0)

  # How well a swap fits one roster: how many of the incoming players land at
  # a thin position, less any outgoing player that was not actually spare.
  # Zero or below means this side has no reason to do it.
  defp fit_for(outgoing, incoming, depth, opts) do
    gained =
      incoming
      |> Enum.map(&position(&1, opts))
      |> Enum.count(&thin?(depth, &1, opts))

    given_from_need =
      outgoing
      |> Enum.map(&position(&1, opts))
      |> Enum.count(&(not deep?(depth, &1, opts)))

    gained - given_from_need
  end

  defp position(player_id, opts), do: Map.get(opts.positions, to_string(player_id))
  defp value(player_id, opts), do: Map.get(opts.values, to_string(player_id))

  @doc """
  Starting requirements per position, from Sleeper's `roster_positions`.

  `SUPER_FLEX` counts as a quarterback slot — the same reading
  `leagueMarketSettings` uses on the frontend, and the reason a superflex
  league values quarterbacks like a different sport. `FLEX` is deliberately
  not distributed; see the moduledoc on why the need model stops here.
  """
  @spec starters([String.t()]) :: %{String.t() => integer}
  def starters(roster_positions) do
    (roster_positions || [])
    |> Enum.reduce(%{}, fn slot, acc ->
      case slot do
        "SUPER_FLEX" -> Map.update(acc, "QB", 1, &(&1 + 1))
        pos when pos in @tradeable -> Map.update(acc, pos, 1, &(&1 + 1))
        _ -> acc
      end
    end)
  end
end
