defmodule SleeperPlayerApi.Intel.BandwidthSweepTest do
  @moduledoc """
  Re-opens the kernel bandwidth, which §3g chose by measurement and then left
  with a known residual: Oscar Delp reads 59% against an observed 45%, because
  the cap at 1.5 flattens the hazard peak for high-spread players (his sd is
  6.7). §3g says to revisit it "with the §4d model rather than by further
  hand-tuning" — and §4d has since been measured and rejected, so that
  deferral has nowhere to land. This is the re-home.

  `bandwidth(sd) = max(lo, min(hi, mult * sd))`, shipping as
  `max(0.6, min(1.5, 0.4 * sd))`.

  ## What is being traded

  §3g's own table shows the shape: a tighter cap calibrates better and leaves
  more stations reading "no read" — a station with no read is not merely
  imprecise, it is wrong, and it is the number the user is asked to act on.

  | bandwidth | calibration error | stations "no read" |
  | --- | --- | --- |
  | binned (original) | 0.0318 | 29% |
  | 0.4 sd, cap 1.5 (shipping) | 0.0373 | 7% |
  | 0.4 sd, cap 2.0 | 0.0378 | 5% |
  | fixed 3.0 | 0.0494 | 4% |

  Those figures came from the harness that was never saved, so they are not
  comparable to anything here. This measures all three axes together on the
  rebuilt harness: calibration (honesty), Brier (sharpness), and the dead
  station rate.

  ## ANSWERED 2026-08-08: leave it alone

  | bandwidth | calib | Brier | dead |
  | --- | --- | --- | --- |
  | 0.4 sd, cap 1.0 | 0.0087 | 0.1047 | 42.8% |
  | **0.4 sd, cap 1.5 (shipping)** | **0.0091** | **0.1047** | **42.3%** |
  | 0.4 sd, cap 2.0 | 0.0111 | 0.1047 | 42.0% |
  | 0.4 sd, uncapped | 0.0121 | 0.1047 | 41.9% |
  | 0.25 sd, cap 1.5 | 0.0085 | 0.1046 | 42.7% |

  Three reasons nothing changed:

  1. **Brier is flat to four decimals across every candidate.** Bandwidth does
     not affect sharpness at all, so the entire question is about calibration,
     where the whole spread is 0.0036.
  2. **The best candidate wins 0.0006.** That is not worth re-basing the golden
     fixture for, which any bandwidth change would require — `fixture.json` is
     frozen at the shipping value and is the ground truth for the parity test.
  3. **The residual that motivated this is mostly not there.** §3g reports Delp
     at 59% predicted against 45% observed. Measured on this corpus the
     observed rate is **54.5%** (18 of the 33 drafts that reached 39 with him
     free at 35) against 57.9% predicted — 3.4 points, inside the 4.0-point
     average §3g already accepts. I cannot fully reconcile that with the
     plan's 45%; the corpus has grown since (70 drafts here, 72 in production)
     but not enough to explain nine points, so the likelier answer is that the
     original figure was computed differently.

  Also mechanical, and worth knowing before anyone tunes the multiplier: for a
  high-spread player both 0.25 sd and 0.4 sd land above the cap (Delp's sd is
  6.7, so 1.675 and 2.68 both clamp to 1.5) and give *identical* predictions.
  The multiplier only moves low- and medium-spread players — it cannot reach
  the ones the cap was blamed for.

  The dead-station column here is **not** comparable to §3g's. Theirs counted
  gauntlet stations for real UI targets; this counts every corpus player near
  their own ADP, which is dominated by one-draft noise players. It barely
  moves (41.5–42.8%) and should not be read as refuting §3g's 4–29% range.

  Tagged `:corpus` and `:measure`.
  """
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.CorpusFixture
  alias SleeperPlayerApi.Intel.{Calibration, Estimator}

  @moduletag :corpus
  @moduletag :measure
  @moduletag timeout: :infinity

  @deltas [1, 3, 6, 9, 12]
  @grid 1..80

  # Candidates. `:infinity` is the uncapped case §3g never tried — the point
  # of the cap is to stop a volatile player's mass smearing across the board,
  # and whether that is worth its calibration cost is exactly the question.
  @candidates [
    {"0.4 sd, cap 1.0", 0.4, 1.0},
    {"0.4 sd, cap 1.5  (shipping)", 0.4, 1.5},
    {"0.4 sd, cap 2.0", 0.4, 2.0},
    {"0.4 sd, cap 3.0", 0.4, 3.0},
    {"0.4 sd, uncapped", 0.4, :infinity},
    {"0.6 sd, cap 2.0", 0.6, 2.0},
    {"0.25 sd, cap 1.5", 0.25, 1.5}
  ]

  defp bandwidth(sd, mult, :infinity), do: max(0.6, mult * sd)
  defp bandwidth(sd, mult, cap), do: (mult * sd) |> min(cap) |> max(0.6)

  # Rebuilt from the public pieces rather than by parameterising production —
  # this is a measurement, and it should not require a shipping change to run.
  # Mirrors `Estimator.base_hazard/3` exactly, clamp included.
  defp hazard_for(drafts, player_id, mult, cap) do
    events = Estimator.player_events(drafts, player_id)
    bw = bandwidth(Estimator.population_stdev(events), mult, cap)
    density = Estimator.density_curve(events, bw, @grid)
    risk = Estimator.risk_curve(drafts, player_id, @grid)

    for {n, r} <- risk, into: %{} do
      {n, if(r == 0, do: 0.0, else: min(1.0, Map.fetch!(density, n) / r))}
    end
  end

  defp estimator(mult, cap) do
    fn training, _board ->
      cache = :ets.new(:hazards, [:set, :private])

      fn player_id, from, to, _gone ->
        hazard =
          case :ets.lookup(cache, player_id) do
            [{^player_id, cached}] ->
              cached

            [] ->
              computed = hazard_for(training, player_id, mult, cap)
              :ets.insert(cache, {player_id, computed})
              computed
          end

        Estimator.base_survival(hazard, from, to)
      end
    end
  end

  # A "dead station": the UI renders "no read" below 1%, so this is the share
  # of picks *near a player's own ADP* — where a read should exist — that come
  # back under that threshold.
  defp dead_station_rate(drafts, mult, cap) do
    players = Calibration.corpus_players(drafts)
    adp = Calibration.observed_adp(drafts, players)

    {dead, total} =
      Enum.reduce(players, {0, 0}, fn player, {dead, total} ->
        case Map.get(adp, player) do
          nil ->
            {dead, total}

          a ->
            hazard = hazard_for(drafts, player, mult, cap)
            window = round(a - 3)..round(a + 3)//1

            Enum.reduce(window, {dead, total}, fn k, {d, t} ->
              if k < 1,
                do: {d, t},
                else: {d + if(Map.get(hazard, k, 0.0) < 0.01, do: 1, else: 0), t + 1}
            end)
        end
      end)

    if total == 0, do: 0.0, else: dead / total
  end

  test "sweeps the kernel bandwidth on calibration, sharpness and dead stations" do
    drafts = CorpusFixture.drafts()

    rows =
      Enum.map(@candidates, fn {label, mult, cap} ->
        result = Calibration.run(drafts, estimator(mult, cap), deltas: @deltas)
        {label, result.contested, dead_station_rate(drafts, mult, cap)}
      end)

    IO.puts("""

    === Kernel bandwidth sweep (contested population, n=#{elem(hd(rows), 1).n}) ===

    #{String.pad_trailing("bandwidth", 30)} calib     Brier     dead stations
    """)

    for {label, r, dead} <- rows do
      IO.puts(
        "    #{String.pad_trailing(label, 30)} " <>
          "#{r.error |> Float.round(4) |> to_string() |> String.pad_trailing(10)}" <>
          "#{r.brier |> Float.round(4) |> to_string() |> String.pad_trailing(10)}" <>
          "#{(dead * 100) |> Float.round(1)}%"
      )
    end

    IO.puts("""

      Lower is better on all three. The shipping row is the incumbent; a
      challenger has to be better on calibration or Brier without giving back
      the dead-station rate §3g bought.
    """)

    assert length(rows) == length(@candidates)
  end
end
