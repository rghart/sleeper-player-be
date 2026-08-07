defmodule SleeperPlayerApi.Intel.CalibrationBaselineTest do
  @moduledoc """
  The measurement §6 step 5 is gated on: the shipping estimator against the
  §4d manager-conditioned candidate, scored by `Intel.Calibration` over the
  real corpus with identical settings.

  Both are measured in one run, on both populations, and the populations were
  defined and committed before either number was seen. The plan's 0.0296 is
  not the comparison — that harness was never saved, so the figure is not
  reproducible; what matters is the two models scored here, the same way.

  Tagged `:corpus` (gitignored data) and `:measure` (slow).
  """
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.CorpusFixture
  alias SleeperPlayerApi.Intel.{Calibration, Estimator, ManagerModel}

  @moduletag :corpus
  @moduletag :measure
  @moduletag timeout: :infinity

  @deltas [1, 3, 6, 9, 12]

  # As it ships: one league-wide smoothed hazard, no manager conditioning.
  # `base_survival/3` is already conditional on availability at `from`, which
  # is exactly the quantity being scored.
  defp shipping do
    fn training, _board ->
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

  # §4d: a Plackett-Luce choice model per manager, fitted per training corpus.
  defp manager_conditioned do
    fn training, board ->
      fitted = ManagerModel.fit(training, board: board)
      fn player_id, from, to -> ManagerModel.survival(fitted, player_id, from, to) end
    end
  end

  defp report(label, result) do
    IO.puts("\n  #{label}")

    for pop <- [:all, :contested] do
      r = Map.fetch!(result, pop)
      IO.puts("    #{pop}: error #{Float.round(r.error, 4)}  (n=#{r.n})")
    end
  end

  test "scores the shipping estimator against the §4d manager-conditioned model" do
    drafts = CorpusFixture.drafts()
    assert length(drafts) == 70

    baseline = Calibration.run(drafts, shipping(), deltas: @deltas)
    candidate = Calibration.run(drafts, manager_conditioned(), deltas: @deltas)

    IO.puts("\n=== §6 step 5 gate ===")
    report("shipping (league-wide smoothed hazard)", baseline)
    report("candidate (§4d manager-conditioned)", candidate)

    verdict = fn pop ->
      b = Map.fetch!(baseline, pop).error
      c = Map.fetch!(candidate, pop).error

      "#{pop}: #{if c < b, do: "candidate wins", else: "baseline wins"} " <>
        "(#{Float.round(b, 4)} vs #{Float.round(c, 4)})"
    end

    IO.puts("""

      #{verdict.(:all)}
      #{verdict.(:contested)}

    The contested population is the one that discriminates; `all` is dominated
    by foregone conclusions. If the candidate does not win there, §6 step 5
    says it has not earned its complexity.
    """)

    # Sanity floors only — the verdict above is the deliverable, and asserting
    # a direction here would turn a measurement into a foregone conclusion.
    assert baseline.contested.n > 1_000
    assert candidate.contested.n == baseline.contested.n
  end
end
