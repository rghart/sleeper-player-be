defmodule SleeperPlayerApiWeb.FaabController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.FaabMarket

  action_fallback SleeperPlayerApiWeb.FallbackController

  # One claim is a real observation and the response says so with `claims`, so
  # the default hides nothing. A caller wanting only well-sampled players asks
  # for them rather than being given a filtered list it cannot tell from a
  # complete one.
  @default_min_claims 1
  @max_min_claims 100

  @doc """
  `GET /api/v1/faab?minClaims=` — what players actually went for in the
  observed leagues, as a share of each paying league's budget.

  Not a projection: these are winning waiver claims that happened, in leagues
  the manager's own leaguemates are in. Every entry carries `claims`,
  `leagues` and the `low`/`high` spread alongside the median, and the response
  carries the `window` those bids fall in — the prices are meaningless without
  them, and a caller cannot fetch one without the others.
  """
  def index(conn, params) do
    with {:ok, min_claims} <- parse_min_claims(params["minClaims"]) do
      render(conn, :index, market: FaabMarket.prices(min_claims: min_claims))
    end
  end

  defp parse_min_claims(nil), do: {:ok, @default_min_claims}

  defp parse_min_claims(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 and n <= @max_min_claims ->
        {:ok, n}

      {n, ""} ->
        {:error, {:param_out_of_range, :minClaims, n, 1, @max_min_claims}}

      _ ->
        {:error, {:invalid_param, :minClaims, raw}}
    end
  end

  defp parse_min_claims(raw), do: {:error, {:invalid_param, :minClaims, raw}}
end
