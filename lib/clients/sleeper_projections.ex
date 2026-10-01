defmodule SleeperPlayerApi.Client.SleeperProjections do
  @moduledoc """
  Sleeper's projections service. Unofficial and keyless like the rest of
  Sleeper's API, but on a different host (`api.sleeper.com`, not
  `api.sleeper.app/v1`), which is why it is not a path on
  `SleeperPlayerApi.Client.Sleeper`.

  Same shape as the other clients: a non-raising `get/1` returning tagged
  tuples, and a base URL read from Application env so tests can point it at
  Bypass. Throttled through the shared `RateLimiter` because it is still
  Sleeper's infrastructure.
  """

  use HTTPoison.Base

  alias SleeperPlayerApi.RateLimiter

  @projections_url "https://api.sleeper.com"

  # Fantasy-relevant positions only. Without them the response includes
  # every IDP too, several times the size.
  @positions ~w(QB RB WR TE K DEF)

  def process_request_url(url), do: base_url() <> url

  # Production never sets `:sleeper_projections_base_url`; tests do.
  defp base_url do
    Application.get_env(:sleeper_player_api, :sleeper_projections_base_url, @projections_url)
  end

  def process_response_body(body), do: body

  @doc """
  Every regular-season projection for `season`: a list of rows with
  `"player_id"`, `"stats"` and `"last_modified"` (epoch millis), among other
  fields. About 3MB for ~3,300 players.

  Returns `{:ok, rows}`, `{:error, {:http_error, status}}`,
  `{:error, {:invalid_json, status}}` or `{:error, {:transport_error, reason}}`.
  """
  def season(season) do
    query =
      URI.encode_query([season_type: "regular"] ++ Enum.map(@positions, &{"position[]", &1}))

    RateLimiter.throttle()

    case get("/projections/nfl/#{season}?#{query}") do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          {:ok, _} -> {:error, {:invalid_json, status}}
          {:error, _} -> {:error, {:invalid_json, status}}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:transport_error, reason}}
    end
  end
end
