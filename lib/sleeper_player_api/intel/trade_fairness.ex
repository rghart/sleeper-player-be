defmodule SleeperPlayerApi.Intel.TradeFairness do
  @moduledoc """
  How even a trade is, measured against trades real managers accepted
  (docs/dynasty-engine.md, M4).

  A trade's *gap* is `|a - b| / max(a, b)` on KTC value after `TradeValue`'s
  package adjustment - the same measure the trade search uses to call a trade
  even. `real_trade_quantiles` (config) is that gap's distribution across
  real Sleeper trades, every 5th percentile from 0 to 100, measured with
  `priv/calibration/real_trade_gaps.exs`.

  **What the first measurement said** (2026-10-01): across 1,183 completed
  two-team trades in 138 dynasty leagues from January to October 2026, each
  valued on KTC as of its own date, the median gap was 23.5%; only a quarter
  were within 12%. Player-only trades were a little tighter (median 19%),
  and tight-end trades in TE-premium leagues were no worse than the rest, so
  the spread is not an artifact of the base history ignoring TE premium.
  Managers simply trade at real distances from any one market's numbers.

  So `fair_band` moved from a guessed 12% to 20% (about the median accepted
  gap), and every idea says where its gap falls among real trades, so a
  caller can tell a comfortable deal from a stretch.
  """

  @default_quantiles [
    0.0,
    0.0266,
    0.0528,
    0.072,
    0.0956,
    0.1218,
    0.1413,
    0.1654,
    0.1857,
    0.211,
    0.2348,
    0.2615,
    0.2896,
    0.3187,
    0.3489,
    0.3806,
    0.4138,
    0.4709,
    0.5203,
    0.584,
    0.9707
  ]

  @doc "The real-trade gap distribution, every 5th percentile, from config."
  def quantiles do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:real_trade_quantiles, @default_quantiles)
  end

  @doc "A trade's gap: how far apart its two sides are, as a share of the larger."
  def gap(a, b) do
    larger = max(a, b)
    if larger > 0, do: abs(a - b) / larger, else: 0.0
  end

  @doc """
  The share of real trades that were *less* even than a trade with this gap,
  0 to 1: 0.8 means more even than 80% of the trades managers accepted.
  Interpolated between the stored percentiles.
  """
  def more_even_than(gap) do
    qs = quantiles()
    n = length(qs) - 1

    below =
      qs
      |> Enum.with_index()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(fn [{lo, i}, {hi, _}] ->
        cond do
          gap <= lo -> i / n
          gap <= hi and hi > lo -> (i + (gap - lo) / (hi - lo)) / n
          true -> nil
        end
      end)

    1.0 - (below || 1.0)
  end
end
