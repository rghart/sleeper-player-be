defmodule SleeperPlayerApi.Intel.CalibrationBaselineTest do
  @moduledoc """
  The measurement §6 step 5 is gated on: what the *current* estimator scores,
  measured by `Intel.Calibration` against the real corpus.

  This is the baseline a manager-conditioned model has to beat. It is a
  measurement, not an assertion about a target — the plan quotes 0.0296 from a
  harness that was never saved, so that figure is not reproducible and is not
  what this compares against. What matters is that both estimators are scored
  by *this* harness with identical settings.

  Tagged `:corpus` (gitignored data) and `:measure` (slow — leave-one-out over
  70 drafts refits every player's hazard 70 times).
  """
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.CorpusFixture
  alias SleeperPlayerApi.Intel.{Calibration, Estimator}

  @moduletag :corpus
  @moduletag :measure
  @moduletag timeout: :infinity

  # The estimator as it ships today: a league-wide smoothed hazard, with no
  # manager conditioning at all. `base_survival/3` is already conditional on
  # availability at `from`, which is exactly the quantity being scored.
  defp current_estimator do
    fn training ->
      cache = :ets.new(:hazards, [:set, :private])

      fn player_id, from, to ->
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

    result = Calibration.run(drafts, current_estimator(), deltas: [1, 3, 6, 9, 12])

    rows =
      result.buckets
      |> Enum.map_join("\n", fn b ->
        "  #{Float.round(b.bucket, 1)}–#{Float.round(b.bucket + 0.1, 1)}  " <>
          "n=#{String.pad_leading(to_string(b.n), 7)}  " <>
          "predicted #{Float.round(b.mean_predicted, 3)}  " <>
          "observed #{Float.round(b.observed, 3)}"
      end)

    IO.puts("""

    Conditional calibration — shipping estimator (league-wide smoothed hazard)
    #{rows}

      observations: #{result.n}
      weighted error: #{Float.round(result.error, 4)}
    """)

    # Not a target, a floor: a number this far out would mean the harness or
    # the corpus load is broken, not that the model is bad. The real gate for
    # step 5 is beating this figure with a manager-conditioned model, measured
    # the same way.
    assert result.n > 100_000
    assert result.error < 0.2
  end
end
