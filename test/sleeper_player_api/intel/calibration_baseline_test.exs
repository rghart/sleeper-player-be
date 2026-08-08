defmodule SleeperPlayerApi.Intel.CalibrationBaselineTest do
  @moduledoc """
  What the shipping estimator scores, measured by `Intel.Calibration` over the
  real corpus. This is the baseline any future model has to beat, and it is
  also a regression guard: it is what caught survival going negative (a hazard
  above 1.0 for the consensus 1.01 at pick 2), which no unit test had.

  Not a target. The plan quotes 0.0296 from a harness that was never saved, so
  that figure is not reproducible and is not what this compares against — what
  matters is that a challenger is scored *here*, with identical settings.

  ## §4d has already been measured and lost

  The manager-conditioned model of plan §4d was built and scored against this
  baseline on 2026-08-07:

  | population | shipping | §4d |
  | --- | --- | --- |
  | all | **0.0017** | 0.0378 |
  | contested | **0.0091** | 0.2120 |

  23x worse where it counts, so per §6 step 5 it did not earn its complexity
  and is not in this repo. It lives on the `candidate/manager-model` branch
  with the head-to-head test that produced those numbers.

  The reason is structural and worth knowing before anyone tries again: that
  model conditions on *who* picks and never on *when*. A conditional logit
  over static values gives a player a near-flat hazard across the whole draft
  — 0.002 at pick 5, 0.002 at 22 and 0.002 at 45, for a player whose observed
  ADP is 20.7 — where the empirical kernel hazard puts 0.01 at 22 and ~0
  elsewhere. *When* a player goes is the entire question. Conditioning on the
  manager rescales a curve with the wrong shape in time; the incumbent applies
  manager information *to* an empirical time curve, which is why it wins.

  Tagged `:corpus` (gitignored data) and `:measure` (slow).
  """
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.CorpusFixture
  alias SleeperPlayerApi.Intel.{Calibration, Estimator}

  @moduletag :corpus
  @moduletag :measure
  @moduletag timeout: :infinity

  @deltas [1, 3, 6, 9, 12]

  # As it ships: one league-wide smoothed hazard. `base_survival/3` is already
  # conditional on availability at `from`, which is the quantity being scored.
  defp shipping do
    fn training, _board ->
      cache = :ets.new(:hazards, [:set, :private])

      fn player_id, from, to, _gone ->
        hazard =
          case :ets.lookup(cache, player_id) do
            [{^player_id, cached}] ->
              cached

            [] ->
              computed = Estimator.base_hazard(training, player_id)
              :ets.insert(cache, {player_id, computed})
              computed
          end

        Estimator.base_survival(hazard, from, to)
      end
    end
  end

  test "measures the shipping estimator, and prints the baseline to beat" do
    drafts = CorpusFixture.drafts()
    assert length(drafts) == 70

    result = Calibration.run(drafts, shipping(), deltas: @deltas)

    rows =
      Enum.map_join(result.all.buckets, "\n", fn b ->
        "  #{Float.round(b.bucket, 1)}–#{Float.round(b.bucket + 0.1, 1)}  " <>
          "n=#{String.pad_leading(to_string(b.n), 7)}  " <>
          "predicted #{Float.round(b.mean_predicted, 3)}  " <>
          "observed #{Float.round(b.observed, 3)}"
      end)

    IO.puts("""

    Conditional calibration — shipping estimator (league-wide smoothed hazard)
    #{rows}

      all:       error #{Float.round(result.all.error, 4)}  (n=#{result.all.n})
      contested: error #{Float.round(result.contested.error, 4)}  (n=#{result.contested.n})

    `contested` is the number a challenger has to beat; `all` is dominated by
    foregone conclusions.
    """)

    # Every prediction is a probability. This is the assertion that would have
    # caught the negative-survival bug, so it is not decoration.
    for pop <- [result.all, result.contested], bucket <- pop.buckets do
      assert bucket.mean_predicted >= 0.0 and bucket.mean_predicted <= 1.0
    end

    assert result.contested.n > 1_000
  end
end
