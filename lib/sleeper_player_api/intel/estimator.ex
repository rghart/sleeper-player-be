defmodule SleeperPlayerApi.Intel.Estimator do
  @moduledoc """
  Pure survival estimator for "how long will this rookie last" in a leaguemate
  draft-intel feature.

  No Ecto, no Repo, no HTTP — every function here takes plain Elixir data
  structures (maps/lists) and returns numbers. A DB-backed adapter builds the
  inputs; this module never reaches for them itself. That split is what makes
  this testable without Postgres.

  This moduledoc is the durable copy of the formulas that were originally
  reverse-engineered (by fitting against a known-good fixture output) in a
  gitignored spec doc. The spec doc is a working note; **this is the
  reference** going forward.

  ## Vocabulary

  | Term | Meaning |
  | --- | --- |
  | Corpus | The completed rookie drafts observed across all leaguemates. |
  | Normalized pick | A pick number rescaled to a 12-team equivalent. All maths happens in this space. |
  | League ADP | Mean normalized pick across the corpus, for one player. |
  | Market ADP / rank | Rank within the rookie class by FantasyCalc trade value. |
  | Manager ADP | One manager's own mean normalized pick for a player. |
  | Gap | `leagueAdp - marketPick`. Positive = your circle lets him slide. |
  | Base hazard | League-wide probability the player goes at pick `n`, given still available. |
  | Adjusted hazard | Base hazard scaled by the multiplier for whoever owns pick `n`. |
  | Survival | Probability he is still on the board at a pick, conditional on being available now. |

  ## 1. Inputs

  A **draft** is represented as a plain map:

      %{
        l_d: float,          # normalized last pick ACTUALLY MADE in this draft
                              # (norm(max pick_no, teams) — not teams * rounds)
        picks: [
          %{norm: float, player_id: String.t(), manager: String.t() | nil}
        ]
      }

  `manager` is the leaguemate's display name (or `nil` if the picking user
  isn't one of the tracked leaguemates — those picks still count for the
  base hazard, they just can't contribute to any manager's seen/took counts).

  ## 2. Normalization

      norm(pick_no, teams) = (pick_no - 1) / teams * 12 + 1

  Fractional; deliberately not rounded — rounding normalized picks to
  integers measurably hurts the fit (mean error 0.00024 -> 0.00305 in
  testing). The hazard grid is the integers `1..80` by default (adequate for
  4-round/12-team drafts; pass a wider grid for bigger formats).

  ## 3. League ADP and spread

  Over the set of normalized picks for player X across drafts where he was
  taken:

      n   = count
      adp = mean
      sd  = POPULATION standard deviation   # divide by n, NOT n - 1
      min, max = extremes

  `sd` must be the *population* deviation. Sample deviation (`n - 1`) is off
  by ~0.1 on almost every player — small enough to look like rounding — and
  it feeds the kernel bandwidth below, so the error propagates into the
  hazard curve. Elixir's stdlib has no stdev function; `population_stdev/1`
  is hand-rolled and unit-tested against known values.

  ## 4. Base hazard — Kaplan-Meier with a smeared numerator

  Bandwidth, per player, from that player's own spread:

      bw = max(0.6, min(1.5, 0.4 * sd))

  For each grid pick `n`:

                     sum over drafts where X was taken:  K(n; e_d, bw)
      density d(n) = ------------------------------------------------
                              (each event contributes total mass 1)

      risk    r(n) = count of { d : L_d >= n AND (X not taken in d OR e_d >= n) }

      hazard  h(n) = d(n) / r(n)     (0 when r(n) = 0)

  where the kernel is a Gaussian normalized over the *whole grid* so each
  observed event contributes exactly 1.0 of total mass:

      gauss(n, e, bw) = exp(-0.5 * ((n - e) / bw) ** 2)
      K(n; e, bw)     = gauss(n, e, bw) / sum_{m in grid} gauss(m, e, bw)

  See `density_curve/3` for the smeared numerator and `risk_curve/3` for the
  **unsmeared** risk set — read the comment on `risk_curve/3` before touching
  it, the asymmetry is deliberate.

  ## 5. Survival

  Both curves are conditional on the player being available at the current
  pick, and are products over the picks from `current_pick` up to (not
  including) the target pick:

      baseSurvival(N) = product_{k = current_pick}^{N-1} (1 - h(k))
      adjSurvival(N)  = product_{k = current_pick}^{N-1} (1 - h(k) * mult(owner(k), X))

  So `baseSurvival(current_pick) = adjSurvival(current_pick) = 1.0` by
  construction (empty product). `owner(k)` is the trade-resolved owner of
  pick `k` — resolution itself is out of scope here, callers pass in the
  already-resolved `pick -> manager` board.

  ## 6. Manager multiplier

  Per-draft base rate that a given manager takes player X, league-wide:

      base(X) = (n_X / D) / 12

  `n_X` = drafts in which X was taken at all, `D` = corpus size. The `/12` is
  the 12-team normalization.

  Then, for manager `m` with `seen_m` drafts observed:

      seen_m = 0   ->  mult = 1.0   (exactly; league average — no data, no opinion)

      otherwise:
        rate   = took_{m,X} / seen_m
        lambda = seen_m / (seen_m + 8)     # shrinkage of the observed RATE toward base(X)
        w      = seen_m / (seen_m + 12)    # confidence weight on the MULTIPLIER itself
        shrunk = lambda * rate + (1 - lambda) * base(X)
        mult   = 1 + w * (shrunk / base(X) - 1)

  These are **two different constants applied in series** — `lambda` uses
  `+8`, `w` uses `+12`. Do not unify them into one shrinkage; they were
  recovered independently by fitting the zero-take rows (where `mult`
  collapses to `1 - w * lambda`, independent of the player) across
  `seen in {1, 3, 4, 5, 23, 24, 30}`.

  ## 7. Threats

  For target pick `N`, the threat list is every pick `k` in
  `[current_pick, N)` whose owner is a known leaguemate, in pick order:

      threats[k] = %{manager: owner(k), pick: k,
                      prob: h(k) * mult(owner(k), X),
                      drafts: seen_owner, tookCount: took_{owner,X}}

  `drafts` and `tookCount` are the sample-size receipts every figure must
  carry — they are not optional decoration.

  ## 8. Market layer

      marketPick = rank within the ROOKIE CLASS by FantasyCalc `value`, descending
      adpGap     = round(leagueAdp - marketPick, 1)

  Rookie class, not the full player pool — ranking the full pool gives
  numbers that are internally consistent and completely wrong. A player has
  no `marketPick` (and so no `adpGap`) if the market-value feed doesn't flag
  him as part of the class at all.
  """

  @default_grid_max 80

  # ---------------------------------------------------------------------
  # 2. Normalization
  # ---------------------------------------------------------------------

  @doc """
  `norm(pick_no, teams) = (pick_no - 1) / teams * 12 + 1`

  Rescales an absolute pick number to its 12-team-equivalent position.
  Deliberately fractional — do not round the result.
  """
  @spec normalize_pick(number, number) :: float
  def normalize_pick(pick_no, teams) do
    (pick_no - 1) / teams * 12 + 1
  end

  # ---------------------------------------------------------------------
  # 3. League ADP and spread
  # ---------------------------------------------------------------------

  @doc """
  Population standard deviation (divide by `n`, not `n - 1`).

  Elixir's stdlib has no stdev function. This one is population, deliberately
  — sample deviation is off by ~0.1 on almost every player in the reference
  corpus, which is small enough to look like rounding error but is wrong
  16/16 against the known-good fixture, because it feeds the kernel
  bandwidth in `bandwidth/1` and the error propagates from there.
  """
  @spec population_stdev([number]) :: float
  def population_stdev([]), do: 0.0

  def population_stdev(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n
    :math.sqrt(variance)
  end

  @doc """
  League ADP summary for one player: `n`, `adp` (mean), `sd` (population),
  `min`, `max` — over the normalized picks at which he was actually taken.

  `events` is the list of normalized pick numbers (see `normalize_pick/2`)
  across every corpus draft in which the player was drafted. Returns `nil`
  for an empty list — a player absent from the corpus has no ADP, on
  purpose (see moduledoc "Not pinned" territory; callers decide what to do
  with `nil`).
  """
  @spec adp_summary([number]) ::
          %{
            n: non_neg_integer,
            adp: float,
            sd: float,
            min: float,
            max: float
          }
          | nil
  def adp_summary([]), do: nil

  def adp_summary(events) do
    n = length(events)

    %{
      n: n,
      adp: Enum.sum(events) / n,
      sd: population_stdev(events),
      min: Enum.min(events) * 1.0,
      max: Enum.max(events) * 1.0
    }
  end

  # ---------------------------------------------------------------------
  # 4. Base hazard
  # ---------------------------------------------------------------------

  @doc """
  Kernel bandwidth for a player's density smear, from that player's own
  population sd: `max(0.6, min(1.5, 0.4 * sd))`.
  """
  @spec bandwidth(number) :: float
  def bandwidth(sd) do
    (0.4 * sd)
    |> min(1.5)
    |> max(0.6)
  end

  @doc """
  Every normalized pick at which `player_id` was taken, across all `drafts`,
  flattened (order not meaningful). Feeds `adp_summary/1` and the density
  curve.
  """
  @spec player_events([map], String.t()) :: [float]
  def player_events(drafts, player_id) do
    for draft <- drafts,
        pick <- draft.picks,
        pick.player_id == player_id,
        do: pick.norm
  end

  @doc """
  The smeared numerator: for each grid point `n`, the sum of every observed
  event's Gaussian kernel mass at `n`, where each event's kernel is
  normalized over the *whole grid* so it contributes exactly 1.0 of total
  mass. This is the §3g "dead station" fix — a single observed pick smears
  its probability mass across nearby picks instead of voting for one exact
  integer.
  """
  @spec density_curve([number], number, Enumerable.t()) :: %{integer => float}
  def density_curve(events, bw, grid \\ default_grid()) do
    grid_list = Enum.to_list(grid)

    base = for n <- grid_list, into: %{}, do: {n, 0.0}

    Enum.reduce(events, base, fn e, density ->
      weights = for n <- grid_list, do: {n, gauss(n, e, bw)}
      total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      Enum.reduce(weights, density, fn {n, w}, acc ->
        contribution = if total == 0, do: 0.0, else: w / total
        Map.update!(acc, n, &(&1 + contribution))
      end)
    end)
  end

  defp gauss(n, e, bw) do
    z = (n - e) / bw
    :math.exp(-0.5 * z * z)
  end

  @doc """
  The risk set at each grid pick `n`: the count of drafts still "in play" for
  this player at that pick.

  **This is intentionally NOT smeared, even though the numerator is.** A
  draft leaves the risk set *hard*, at the exact unsmeared pick the player
  was actually taken (`e_d`) — not fractionally, as the kernel mass drains
  away in `density_curve/3`.

  This looks like an inconsistency (why smear one side and not the other?)
  and it WILL look like a bug to someone reading this later. It is not one.
  Fractional risk-set decay was tried and measured: it produces plausible
  numbers that are wrong in the direction that flatters (survival reads too
  high), concentrated exactly on players whose ADP falls before the pick
  being evaluated — the same failure signature as a known censoring bug in
  the plan this was ported from. Mean error against the reference fixture:
  0.0082 fractional vs 0.00024 hard. Do not "fix" this into a fractional
  decay; that is the regression, not an improvement. See
  `estimator_test.exs` for the pinned regression test.

  A draft counts toward the risk set at `n` when its last-made pick
  (`l_d`) hasn't ended the draft before `n` yet, AND the player either
  wasn't taken in that draft at all, or was taken at or after `n`.
  """
  @spec risk_curve([map], String.t(), Enumerable.t()) :: %{integer => non_neg_integer}
  def risk_curve(drafts, player_id, grid \\ default_grid()) do
    per_draft_events =
      for draft <- drafts do
        events = for pick <- draft.picks, pick.player_id == player_id, do: pick.norm
        {draft.l_d, events}
      end

    for n <- Enum.to_list(grid), into: %{} do
      count =
        Enum.count(per_draft_events, fn {l_d, events} ->
          l_d >= n and (events == [] or Enum.any?(events, &(&1 >= n)))
        end)

      {n, count}
    end
  end

  @doc """
  Base hazard curve `h(n) = d(n) / r(n)` (0 when the risk set is empty) for
  every grid pick, for one player, derived straight from `drafts`.

  Convenience wrapper around `density_curve/3` and `risk_curve/3` that also
  derives the bandwidth from the player's own population sd — the thing
  most callers actually want.
  """
  @spec base_hazard([map], String.t(), Enumerable.t()) :: %{integer => float}
  def base_hazard(drafts, player_id, grid \\ default_grid()) do
    events = player_events(drafts, player_id)
    sd = events |> population_stdev()
    bw = bandwidth(sd)

    density = density_curve(events, bw, grid)
    risk = risk_curve(drafts, player_id, grid)

    for {n, r} <- risk, into: %{} do
      h = if r == 0, do: 0.0, else: Map.fetch!(density, n) / r
      {n, h}
    end
  end

  defp default_grid, do: 1..@default_grid_max

  # ---------------------------------------------------------------------
  # 5. Survival
  # ---------------------------------------------------------------------

  @doc """
  `baseSurvival(N) = product_{k=current_pick}^{N-1} (1 - h(k))`

  Conditional on the player being available at `current_pick`; equals `1.0`
  when `target_pick <= current_pick` (empty product).
  """
  @spec base_survival(%{integer => float}, integer, integer) :: float
  def base_survival(hazard, current_pick, target_pick) do
    Enum.reduce(current_pick..(target_pick - 1)//1, 1.0, fn k, acc ->
      acc * (1 - Map.get(hazard, k, 0.0))
    end)
  end

  @doc """
  `adjSurvival(N) = product_{k=current_pick}^{N-1} (1 - h(k) * mult(owner(k), X))`

  `mult_fun` is `(pick_number -> multiplier_float)` — already resolved
  against a board, so this function doesn't need to know about managers,
  ownership, or trade resolution at all.
  """
  @spec adjusted_survival(%{integer => float}, integer, integer, (integer -> float)) :: float
  def adjusted_survival(hazard, current_pick, target_pick, mult_fun) do
    Enum.reduce(current_pick..(target_pick - 1)//1, 1.0, fn k, acc ->
      h = Map.get(hazard, k, 0.0)
      acc * (1 - h * mult_fun.(k))
    end)
  end

  # ---------------------------------------------------------------------
  # 6. Manager multiplier
  # ---------------------------------------------------------------------

  @doc """
  League-wide base rate that any given manager takes player `X` in a draft:
  `(n_X / D) / 12`, where `n_X` is how many corpus drafts took `X` at all
  and `D` is the corpus size.
  """
  @spec base_rate([map], String.t()) :: float
  def base_rate(drafts, player_id) do
    d = length(drafts)
    n_x = length(player_events(drafts, player_id))
    if d == 0, do: 0.0, else: n_x / d / 12
  end

  @doc """
  Number of corpus drafts in which `manager` is observed to have
  participated at all (derived from `picked_by` on the picks, not league
  membership).
  """
  @spec manager_seen([map], String.t()) :: non_neg_integer
  def manager_seen(drafts, manager) do
    Enum.count(drafts, fn draft ->
      Enum.any?(draft.picks, &(&1.manager == manager))
    end)
  end

  @doc """
  Number of those drafts in which `manager` drafted `player_id`.
  """
  @spec manager_took([map], String.t(), String.t()) :: non_neg_integer
  def manager_took(drafts, manager, player_id) do
    Enum.count(drafts, fn draft ->
      Enum.any?(draft.picks, &(&1.manager == manager and &1.player_id == player_id))
    end)
  end

  @doc """
  The manager multiplier, given already-derived `seen`, `took`, and
  `base_rate` — the pure arithmetic core of §6, independent of how those
  three numbers were counted. This is what the "seen = 0 -> 1.0 exactly"
  and "two different shrinkage constants" regression tests exercise
  directly.

      seen = 0  ->  1.0                                    (league average; no opinion)
      otherwise:
        rate   = took / seen
        lambda = seen / (seen + 8)     # shrinks the RATE toward base_rate
        w      = seen / (seen + 12)    # confidence weight on the MULTIPLIER
        shrunk = lambda * rate + (1 - lambda) * base_rate
        mult   = 1 + w * (shrunk / base_rate - 1)

  `lambda` and `w` are deliberately different constants (`+8` vs `+12`),
  applied in series — do not unify them into a single shrinkage factor.

  If `base_rate` is `0.0` (a player no leaguemate in the corpus has ever
  taken — see moduledoc / spec "not pinned" #1), this returns `1.0` rather
  than dividing by zero. That's a documented choice, not a recovered
  behaviour: there is no reference value to fit it against.
  """
  @spec multiplier(non_neg_integer, non_neg_integer, float) :: float
  def multiplier(0, _took, _base_rate), do: 1.0

  def multiplier(_seen, _took, base_rate) when base_rate == 0.0, do: 1.0

  def multiplier(seen, took, base_rate) do
    rate = took / seen
    lambda = seen / (seen + 8)
    w = seen / (seen + 12)
    shrunk = lambda * rate + (1 - lambda) * base_rate
    1 + w * (shrunk / base_rate - 1)
  end

  @doc """
  Convenience wrapper: derives `seen`, `took`, and `base_rate` from `drafts`
  and calls `multiplier/3`. Prefer `multiplier/3` directly in tight loops
  (e.g. computing threats for many picks against the same player) since it
  avoids re-deriving `base_rate` and re-scanning `drafts` on every call.
  """
  @spec manager_multiplier([map], String.t(), String.t()) :: float
  def manager_multiplier(drafts, manager, player_id) do
    seen = manager_seen(drafts, manager)
    took = manager_took(drafts, manager, player_id)
    base = base_rate(drafts, player_id)
    multiplier(seen, took, base)
  end

  # ---------------------------------------------------------------------
  # 7. Threats
  # ---------------------------------------------------------------------

  @doc """
  One entry per pick in `[first_pick, last_pick]` whose owner (per `board`,
  a `%{pick_number => manager}` map) is a known leaguemate: the probability
  that owner takes this player there, given he is still available.

  This is what `threats/8` builds its lists *out of*, and it is the thing
  worth sending over the wire. A threat list for target pick `n` is every
  entry here with `pick < n`, so serving one list per target pick means
  re-sending the same prefix `n` times — measured against production, that
  was 11,760 threat objects and 837KB for ten players at pick 1, where the
  irreducible content is 38KB. The other two fields `threats/8` carries
  (`drafts` and `tookCount`) do not vary by pick either: the first belongs
  to the board entry and the second to `per_manager`, so a caller can
  rebuild the full list by joining on the pick number.

  Picks owned by someone outside `known_managers` are excluded, exactly as
  in `threats/8` — they still affect survival through `mult_fun`, they just
  produce no itemized receipt.
  """
  @spec hazards(
          %{integer => float},
          integer,
          integer,
          %{integer => String.t()},
          MapSet.t(String.t()),
          (String.t() -> float)
        ) :: [map]
  def hazards(hazard, first_pick, last_pick, board, known_managers, mult_fun) do
    for k <- first_pick..last_pick//1,
        manager = Map.get(board, k),
        manager != nil,
        MapSet.member?(known_managers, manager) do
      %{pick: k, prob: Map.get(hazard, k, 0.0) * mult_fun.(manager)}
    end
  end

  @doc """
  The threat list for target pick `target_pick`: every pick `k` in
  `[current_pick, target_pick)` whose owner (per `board`, a `%{pick_number
  => manager}` map) is a known leaguemate, in pick order.

  Retained for tests and for `hazards/6`'s own equivalence check; the API
  serves `hazards/6` instead. See its docstring for why.

  `hazard` is the base hazard curve (see `base_hazard/3`). `known_managers`
  is used to decide whether a board owner is a tracked leaguemate at all —
  picks owned by someone outside that set are excluded from the list (they
  still affect survival via `mult_fun`, just not the itemized threat
  receipts).

  `mult_fun` is `(manager -> multiplier_float)`.
  """
  @spec threats(
          %{integer => float},
          integer,
          integer,
          %{integer => String.t()},
          MapSet.t(String.t()),
          (String.t() -> float),
          (String.t() -> non_neg_integer),
          (String.t() -> non_neg_integer)
        ) :: [map]
  def threats(
        hazard,
        current_pick,
        target_pick,
        board,
        known_managers,
        mult_fun,
        seen_fun,
        took_fun
      ) do
    for k <- current_pick..(target_pick - 1)//1,
        manager = Map.get(board, k),
        manager != nil,
        MapSet.member?(known_managers, manager) do
      mult = mult_fun.(manager)
      h = Map.get(hazard, k, 0.0)

      %{
        manager: manager,
        pick: k,
        prob: h * mult,
        drafts: seen_fun.(manager),
        tookCount: took_fun.(manager)
      }
    end
  end

  # ---------------------------------------------------------------------
  # 8. Market layer
  # ---------------------------------------------------------------------

  @doc """
  Rank of each entry within `rookie_class_entries` by descending `value`
  (ties keep encounter order), 1-indexed — `marketPick` in §8. Callers are
  responsible for filtering `entries` down to the rookie class first (see
  moduledoc — this is not overall rank, and ranking the full pool gives
  numbers that are internally consistent and completely wrong).

  `entries` is a list of `{player_id, value}` pairs.
  """
  @spec rookie_class_rank([{String.t(), number}]) :: %{String.t() => pos_integer}
  def rookie_class_rank(entries) do
    entries
    |> Enum.sort_by(fn {_id, value} -> -value end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{id, _value}, rank} -> {id, rank} end)
    |> Map.new()
  end

  @doc """
  `adpGap = round(leagueAdp - marketPick, 1)`. Returns `nil` when
  `market_pick` is `nil` (player not part of the resolved rookie class).
  """
  @spec adp_gap(number, pos_integer | nil) :: float | nil
  def adp_gap(_league_adp, nil), do: nil

  def adp_gap(league_adp, market_pick) do
    Float.round(league_adp - market_pick * 1.0, 1)
  end
end
