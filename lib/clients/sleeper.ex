defmodule SleeperPlayerApi.Client.Sleeper do
  @moduledoc """
  Thin HTTPoison wrapper around the Sleeper API.

  `get!/1` is the original, still-raising entry point and is what
  `SleeperPlayerApi.Tasks.GetSleeperPlayerData` uses — its behaviour is
  unchanged. `get/1` is a non-raising variant for callers (the
  leaguemate-intel crawler) that need to keep going after a single bad
  response (429, 5xx, a dropped connection) instead of crashing the whole
  job.

  Both are routed through `SleeperPlayerApi.RateLimiter` so a shared token
  bucket enforces Sleeper's documented 1000 calls/min ceiling across every
  concurrent caller, rather than each caller pacing itself.
  """

  use HTTPoison.Base

  alias SleeperPlayerApi.RateLimiter

  @sleeper_url "https://api.sleeper.app/v1"

  def process_request_url(url) do
    base_url() <> url
  end

  # Reads from Application env (rather than baking `@sleeper_url` straight
  # in) so tests can point this at a local Bypass server. Production never
  # sets `:sleeper_base_url`, so this is a no-op outside of tests.
  defp base_url do
    Application.get_env(:sleeper_player_api, :sleeper_base_url, @sleeper_url)
  end

  # Left as the raw body here: the status code isn't available in this
  # callback, and a 429/5xx error page from Sleeper isn't guaranteed to be
  # JSON. Decoding happens below in `get/1` and `get!/1`, where the status
  # code is known and each caller can decide how to react to a bad body.
  def process_response_body(body), do: body

  @doc """
  Non-raising GET. Returns:

    * `{:ok, decoded_body}` on a 2xx response with a JSON body
    * `{:error, {:http_error, status_code}}` on any non-2xx status — this is
      the 429/5xx case a crawler needs to detect and back off on
    * `{:error, {:invalid_json, status_code}}` on a 2xx response whose body
      isn't valid JSON (defensive; shouldn't happen against Sleeper, but a
      caller must not crash if it does)
    * `{:error, {:transport_error, reason}}` on a connection failure
  """
  def get(url, headers \\ [], options \\ []) do
    RateLimiter.throttle()

    case super(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, {:invalid_json, status}}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  Original raising GET. Decodes the JSON body and returns the
  `HTTPoison.Response`, raising on a transport error or an invalid JSON
  body — exactly what this client did before the throttle/`get/1` work.
  `GetSleeperPlayerData` depends on this contract; do not change it here.
  """
  def get!(url, headers \\ [], options \\ []) do
    RateLimiter.throttle()

    super(url, headers, options)
    |> Map.update!(:body, &Jason.decode!/1)
  end
end
