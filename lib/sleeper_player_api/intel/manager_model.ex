defmodule SleeperPlayerApi.Intel.ManagerModel do
  @moduledoc """
  Plan §4d: a manager-conditioned hazard, learned per manager rather than
  applied as a shrunk multiplier over one league-wide curve.

  **This is a candidate, not the shipping model.** §6 step 5 gates it on
  beating what already ships, measured by `SleeperPlayerApi.Intel.Calibration`
  with identical settings. If it does not beat it, it does not earn its
  complexity and should be deleted rather than kept "for later" — the plan is
  explicit about that, and a second estimator nobody scores is worse than none.

  ## The model

  For manager `m` choosing among the players still available at pick `n`:

      h_m(X) = w_m(X) * v(X)^β / Σ_y w_m(y) * v(y)^β

  * `v(X)` — how good the player is, as the corpus sees him. Taken as a
    decaying function of league ADP rather than an external value feed, so
    this stays measurable against the same corpus the estimator uses and does
    not drag FantasyCalc availability into the comparison.
  * `β` — how chalky drafting is. Higher means picks track value more tightly.
    Fitted, not chosen (see `fit_beta/2`).
  * `w_m(X)` — manager affinity, shrunk toward the league baseline so a
    two-draft sample cannot dominate: `1 + λ_m * (rate_m(X) - base(X))` with
    `λ_m = n_m / (n_m + k)`.

  ## Why this might not beat the incumbent

  Worth stating up front, because it shapes how the result should be read. The
  shipping estimator already conditions on managers through the multiplier in
  `Estimator.multiplier/3`, and §3g found that weighting *down* (`n/(n+12)`)
  improved both the D13 error and the held-out Brier score — because for
  managers with 1–3 observed drafts the signal is noise. This model
  conditions harder on the same thin samples. The corpus has 70 drafts across
  13 managers, and the median manager appears in a handful; there may simply
  not be enough per-manager data for a per-manager model to beat a
  well-shrunk league curve.
  """

  alias SleeperPlayerApi.Intel.Estimator

  @shrinkage_k 8

  @doc """
  Player "value" as the corpus sees it: a decaying function of league ADP,
  normalized so the earliest-drafted player is 1.0.

  `exp(-adp / scale)` rather than `1 / adp` — the latter's ratios explode at
  the top of the board (pick 1 is twice pick 2, but pick 40 and 41 are nearly
  identical), which makes `β` fit almost entirely to the first round.
  """
  @spec values([map], [String.t()], number) :: %{String.t() => float}
  def values(drafts, player_ids, scale \\ 24.0) do
    Map.new(player_ids, fn id ->
      case Estimator.player_events(drafts, id) do
        [] -> {id, 0.0}
        events -> {id, :math.exp(-(Enum.sum(events) / length(events)) / scale)}
      end
    end)
  end

  @doc """
  Manager affinity for one player, shrunk toward the league baseline.

  `1.0` exactly when the manager has never been observed — no data, no
  opinion, the same rule `Estimator.multiplier/3` follows.
  """
  @spec affinity(non_neg_integer, non_neg_integer, float) :: float
  def affinity(0, _took, _base), do: 1.0

  def affinity(seen, took, base) do
    lambda = seen / (seen + @shrinkage_k)
    max(0.05, 1 + lambda * (took / seen - base))
  end

  @doc """
  Fits `β` by maximum likelihood over the observed drafts: for each pick, the
  chosen player's share of the available pool under the model, maximised.

  A coarse grid search rather than a solver. The likelihood is smooth and
  one-dimensional here, and a grid makes the fitted value auditable against
  the printed curve — which matters more than the third decimal place.
  """
  @spec fit_beta([map], keyword) :: float
  def fit_beta(drafts, opts \\ []) do
    grid = Keyword.get(opts, :grid, [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0])
    players = for(d <- drafts, p <- d.picks, do: p.player_id) |> Enum.uniq()
    value = values(drafts, players)

    grid
    |> Enum.map(fn beta -> {beta, log_likelihood(drafts, value, beta)} end)
    |> Enum.max_by(fn {_beta, ll} -> ll end)
    |> elem(0)
  end

  @doc """
  Total log-likelihood of the observed picks under the model at `beta`.

  Ignores manager affinity deliberately: `β` describes how tightly the *field*
  tracks value, and fitting it jointly with per-manager terms on 70 drafts
  would let affinity absorb signal that belongs to value.
  """
  @spec log_likelihood([map], %{String.t() => float}, float) :: float
  def log_likelihood(drafts, value, beta) do
    Enum.reduce(drafts, 0.0, fn draft, acc ->
      ordered = Enum.sort_by(draft.picks, & &1.norm)
      pool = MapSet.new(ordered, & &1.player_id)

      {ll, _} =
        Enum.reduce(ordered, {acc, pool}, fn pick, {sum, available} ->
          weights =
            available
            |> Enum.map(fn id -> :math.pow(Map.get(value, id, 0.0), beta) end)
            |> Enum.sum()

          chosen = :math.pow(Map.get(value, pick.player_id, 0.0), beta)

          next =
            if weights > 0 and chosen > 0 do
              sum + :math.log(chosen / weights)
            else
              sum
            end

          {next, MapSet.delete(available, pick.player_id)}
        end)

      ll
    end)
  end

  @doc """
  Survival from `from` to `to` for one player, under the manager-conditioned
  hazard, given the board (`pick -> manager`) and the pool of players assumed
  still available.

  Returns `1.0` when `to <= from` (empty product), matching
  `Estimator.base_survival/3`.
  """
  @spec survival(map, String.t(), number, number) :: float
  def survival(fitted, player_id, from, to) do
    Enum.reduce(trunc(from)..(trunc(to) - 1)//1, 1.0, fn k, acc ->
      acc * (1 - hazard_at(fitted, player_id, k))
    end)
  end

  @doc """
  `h_m(X)` at one pick: the modelled chance the owner of pick `k` takes `X`,
  given `X` is available.
  """
  @spec hazard_at(map, String.t(), integer) :: float
  def hazard_at(fitted, player_id, k) do
    manager = Map.get(fitted.board, k)
    v_x = Map.get(fitted.value, player_id, 0.0)

    if v_x <= 0.0 do
      0.0
    else
      numerator = affinity_for(fitted, manager, player_id) * :math.pow(v_x, fitted.beta)

      denominator =
        Enum.reduce(fitted.pool, 0.0, fn id, acc ->
          v = Map.get(fitted.value, id, 0.0)

          if v <= 0.0,
            do: acc,
            else: acc + affinity_for(fitted, manager, id) * :math.pow(v, fitted.beta)
        end)

      if denominator <= 0.0, do: 0.0, else: min(1.0, numerator / denominator)
    end
  end

  defp affinity_for(_fitted, nil, _player_id), do: 1.0

  defp affinity_for(fitted, manager, player_id) do
    seen = Map.get(fitted.seen, manager, 0)
    took = get_in(fitted.took, [manager, player_id]) || 0
    affinity(seen, took, Map.get(fitted.base, player_id, 0.0))
  end

  @doc """
  Precomputes everything the hazard needs from a training corpus, once.

  Without this the denominator rescans the corpus for every (player, pick)
  pair and a single leave-one-out pass does not finish.
  """
  @spec fit([map], keyword) :: map
  def fit(drafts, opts \\ []) do
    players =
      Keyword.get(opts, :players) ||
        for(d <- drafts, p <- d.picks, do: p.player_id) |> Enum.uniq()

    managers = for(d <- drafts, p <- d.picks, p.manager != nil, do: p.manager) |> Enum.uniq()

    %{
      beta: Keyword.get(opts, :beta) || fit_beta(drafts),
      value: values(drafts, players),
      pool: players,
      base: Map.new(players, &{&1, Estimator.base_rate(drafts, &1) * 12}),
      seen: Map.new(managers, &{&1, Estimator.manager_seen(drafts, &1)}),
      took:
        Map.new(managers, fn manager ->
          {manager, Map.new(players, &{&1, Estimator.manager_took(drafts, manager, &1)})}
        end),
      board: Keyword.get(opts, :board, %{})
    }
  end
end
