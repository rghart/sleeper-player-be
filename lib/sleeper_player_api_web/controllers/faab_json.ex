defmodule SleeperPlayerApiWeb.FaabJSON do
  @moduledoc """
  Renders `Intel.FaabMarket.prices/1` — camelCase keys, same split as the
  other JSON modules here.

  **`window` and `leagues` are not decoration.** Every bid in this corpus was
  made outside the 2026 season, which is a different market from the in-season
  one where most FAAB gets spent, and a UI that renders "12% of budget" without
  saying over what and across how many leagues is overclaiming. They ride on
  the envelope so a caller has them before it renders a single price.
  """

  @doc """
  Prices keyed by Sleeper id, plus the sample behind them.
  """
  def index(%{market: market}) do
    %{
      window: window(market.window),
      leagues: market.leagues,
      players: Map.new(market.players, fn {id, stats} -> {to_string(id), price(stats)} end)
    }
  end

  defp price(stats) do
    %{
      # What he went for in the middle league, as a percentage of that
      # league's budget.
      median: stats.median,
      low: stats.low,
      high: stats.high,
      # The denominator, always. `claims` is winning claims and `leagues` how
      # many distinct leagues they came from — ten claims in one league is a
      # much weaker read than ten across ten.
      claims: stats.claims,
      leagues: stats.leagues,
      # Bids that did not buy him. Sent without interpretation: Sleeper does
      # not say why a claim failed, so "outbid" and "invalid move" look
      # identical from here.
      failed: stats.failed
    }
  end

  defp window(nil), do: nil
  defp window(%{from: from, to: to}), do: %{from: from, to: to}
end
