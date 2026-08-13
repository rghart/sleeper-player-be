defmodule SleeperPlayerApiWeb.DynastyValueController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  # 30 days is the default because that is the window a dynasty manager
  # actually thinks in — "he's been sliding for a month" — and it is long
  # enough that a single news cycle does not dominate it.
  @default_window 30
  @max_window 1000

  @doc """
  `GET /api/v1/dynasty-values?superflex=&window=` — current KeepTradeCut
  values with how far each has moved, plus rookie pick values.

  Distinct from `/values`, which serves FantasyCalc for a *league shape* and
  exists to seed a rank list. This one answers the in-season question: what
  is he worth now, and which way is he going. It is also the only endpoint
  that can price a draft pick.

  `superflex` picks the variant. KTC prices 1QB and superflex separately and
  they are genuinely different games — in superflex the most valuable asset
  is a quarterback — so this is not a cosmetic flag. Defaults to superflex,
  matching the slice the rest of the app is calibrated against.

  `window` is the movement lookback in days. Unparseable or out of range is
  a 422 with the range stated, matching `MarketSettings` and `at_pick` — a
  quiet substitution would answer a question nobody asked.
  """
  def index(conn, params) do
    with {:ok, window} <- parse_window(params["window"]) do
      source = if superflex?(params["superflex"]), do: @superflex, else: @one_qb

      render(conn, :index,
        source: source,
        window: window,
        values: Intel.values_with_movement(source, window),
        picks: Intel.draft_pick_values(source)
      )
    end
  end

  # Absent means the default, not an error — a caller that does not care about
  # the window should not have to name one.
  defp parse_window(nil), do: {:ok, @default_window}

  defp parse_window(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {days, ""} when days > 0 and days <= @max_window ->
        {:ok, days}

      {days, ""} ->
        # Distinct from :invalid_param, because "0 must be an integer" is a
        # false statement — same split the availability controller makes.
        {:error, {:param_out_of_range, :window, days, 1, @max_window}}

      _ ->
        {:error, {:invalid_param, :window, raw}}
    end
  end

  defp parse_window(raw), do: {:error, {:invalid_param, :window, raw}}

  # Only an explicit "false"/"0" turns it off. Anything else — including the
  # bare `?superflex` a hand-built URL produces — means the caller asked for
  # it, and the default is superflex anyway.
  defp superflex?(nil), do: true
  defp superflex?(value) when value in ["false", "0"], do: false
  defp superflex?(_), do: true
end
