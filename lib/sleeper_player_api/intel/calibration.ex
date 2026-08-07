defmodule SleeperPlayerApi.Intel.Calibration do
  @moduledoc """
  Leave-one-draft-out calibration for a survival estimator, scored on the
  question the UI actually asks (plan `docs/leaguemate-intel.md` §3g):
  **given this player is still on the board at pick `k`, is he still there at
  pick `k + d`?**

  This exists because §6 step 5 is gated on a *measurement* rather than a
  review — a manager-conditioned model ships only if it beats what is already
  there. Nothing in either repo could produce that measurement: the harness
  that generated the plan's numbers was never saved, exactly as the estimator
  itself was not (see the estimator moduledoc). So this is a rebuild, and the
  numbers it produces are not guaranteed to match the ones in the plan's
  prose. **Compare estimators against each other through this module; do not
  compare its output to a figure quoted in the plan** — the original's pick
  sampling, bucket edges and weighting are unknown, so an absolute match would
  be luck rather than agreement.

  ## Why the harness is the dangerous part

  §3g records that an earlier version of this scored "not in this draft" as
  *survived* regardless of how far the draft actually ran. Fourteen of the
  seventy corpus drafts are 3-rounders that end at 36 normalized; they cannot
  say anything about pick 39, but they were voting that he lasted. The
  estimator had the same bias, the two cancelled, and the naive version
  therefore looked *better* than the corrected one.

  A harness with a bug in it does not fail loudly — it silently blesses the
  wrong model. So the censoring rule is explicit here and unit-tested against
  hand-computed cases:

    * a `(k, target)` pair is only scored if the draft **reached** `target`
      (`l_d >= target`); otherwise it leaves the risk set entirely
    * the pair is only scored if the player was **still available at `k`**
      (never taken, or taken at `>= k`), which is what makes the probability
      conditional
    * "still available at `target`" likewise means never taken, or taken at
      `>= target`

  ## Metric

  Predictions are bucketed into deciles. Within a bucket, the mean prediction
  is compared to the observed rate, and the absolute gap is weighted by how
  many observations fell in that bucket:

      error = Σ_b (n_b / N) * |mean_predicted_b - observed_rate_b|

  Lower is better. A perfectly calibrated estimator scores 0.0 — which says
  nothing about whether it is *sharp*, only that it is honest. Two estimators
  are only comparable through the same `ks`/`deltas`/bucket settings.
  """

  @default_deltas 1..14
  @buckets 10

  @doc """
  Runs leave-one-draft-out calibration.

  `predict_builder` is `(training_drafts -> predict_fun)`, and `predict_fun`
  is `(player_id, from_pick, to_pick -> probability)`. Taking a builder rather
  than a bare function is what lets an estimator do its per-corpus fitting
  once per held-out draft instead of once per observation — with 70 drafts and
  ~130 players that is the difference between minutes and hours.

  Options:

    * `:deltas` — how far ahead to score, in normalized picks (default 1..14,
      roughly "between now and your next pick" in a 12-team draft)
    * `:ks` — which starting picks to score from (default: every integer pick
      the held-out draft actually reached)
    * `:players` — the candidate pool (default: every player appearing in the
      full corpus)

  Returns `%{error: float, n: integer, buckets: [%{...}]}`.
  """
  @spec run([map], (list -> (String.t(), number, number -> float)), keyword) :: map
  def run(drafts, predict_builder, opts \\ []) do
    deltas = Keyword.get(opts, :deltas, @default_deltas) |> Enum.to_list()
    players = Keyword.get(opts, :players) || corpus_players(drafts)

    observations =
      Enum.flat_map(drafts, fn held_out ->
        training = Enum.reject(drafts, &(&1 == held_out))
        predict = predict_builder.(training)
        score_draft(held_out, players, predict, deltas, opts)
      end)

    summarize(observations)
  end

  @doc """
  Every player id appearing anywhere in `drafts`.
  """
  @spec corpus_players([map]) :: [String.t()]
  def corpus_players(drafts) do
    for(draft <- drafts, pick <- draft.picks, do: pick.player_id) |> Enum.uniq()
  end

  # One held-out draft's worth of (predicted, actual) pairs.
  defp score_draft(held_out, players, predict, deltas, opts) do
    # The earliest pick each player went at in this draft, or nil. `min` and
    # not `hd`: a corpus draft can contain the same player twice only through
    # bad data, but taking whichever came first is the conservative read.
    taken_at =
      Enum.reduce(held_out.picks, %{}, fn pick, acc ->
        Map.update(acc, pick.player_id, pick.norm, &min(&1, pick.norm))
      end)

    last = trunc(held_out.l_d)
    ks = Keyword.get(opts, :ks) || 1..last

    # Every clause here is a filter, including anything that looks like an
    # assignment: `went_at = Map.get(taken_at, player)` reads as a binding but
    # a comprehension treats it as a filter on the *value*, so every player
    # who was never drafted (nil) was silently dropped from the risk set. That
    # is the same shape of error as §3g's original censoring bug — a harness
    # quietly scoring the wrong population — so the conditions are plain
    # boolean calls now and the bindings happen in the body.
    for k <- ks,
        k <= last,
        delta <- deltas,
        # Censoring. A draft that ended before `target` cannot tell us whether
        # he would have lasted to it, so it leaves the risk set rather than
        # voting "survived" forever. This is §3g's Bug 1, and it lived in the
        # harness as well as in the estimator.
        k + delta <= last,
        player <- players,
        # Conditioning: he has to still be on the board at k for "does he last
        # from k to target" to be a question at all.
        available_at?(taken_at, player, k) do
      target = k + delta

      %{
        predicted: predict.(player, k, target),
        actual: available_at?(taken_at, player, target)
      }
    end
  end

  # On the board when pick `n` *starts*. A player taken at exactly `n` was
  # available at `n` — the hazard at `n` is the chance he goes at it, so he is
  # still there when it begins. Both the conditioning and the outcome read
  # through here so the convention cannot drift between them.
  defp available_at?(taken_at, player, n) do
    case Map.get(taken_at, player) do
      nil -> true
      went_at -> went_at >= n
    end
  end

  defp summarize([]), do: %{error: 0.0, n: 0, buckets: []}

  defp summarize(observations) do
    total = length(observations)

    buckets =
      observations
      |> Enum.group_by(&bucket_index(&1.predicted))
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {index, group} ->
        n = length(group)
        mean_predicted = Enum.sum(Enum.map(group, & &1.predicted)) / n
        observed = Enum.count(group, & &1.actual) / n

        %{
          bucket: index / @buckets,
          n: n,
          mean_predicted: mean_predicted,
          observed: observed,
          gap: abs(mean_predicted - observed)
        }
      end)

    error = Enum.reduce(buckets, 0.0, fn b, acc -> acc + b.n / total * b.gap end)

    %{error: error, n: total, buckets: buckets}
  end

  # 1.0 belongs in the top bucket rather than a tenth one of its own.
  defp bucket_index(probability) do
    probability |> Kernel.*(@buckets) |> trunc() |> min(@buckets - 1)
  end
end
