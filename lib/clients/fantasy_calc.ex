defmodule SleeperPlayerApi.Client.FantasyCalc do
  @moduledoc """
  Thin HTTPoison wrapper around the FantasyCalc values API, same shape as
  `SleeperPlayerApi.Client.Sleeper` (plan `docs/leaguemate-intel.md` §2/§3f
  step 5): `use HTTPoison.Base`, a non-raising `get/1` returning tagged
  tuples, and the base URL read from Application env so tests can point it
  at a local Bypass server instead of the real, public, unauthenticated API.

  Unlike the Sleeper client there's no `get!/1` — nothing in this codebase
  needs a raising variant for FantasyCalc, so it isn't built.

  No throttling: FantasyCalc has no documented rate limit, and
  `RefreshPlayerValues` makes exactly one call per run.
  """

  use HTTPoison.Base

  @fantasy_calc_url "https://api.fantasycalc.com"

  def process_request_url(url) do
    base_url() <> url
  end

  # Same trick as `SleeperPlayerApi.Client.Sleeper.base_url/0` — reads from
  # Application env rather than baking `@fantasy_calc_url` straight in, so
  # tests can point this at Bypass. Production never sets
  # `:fantasy_calc_base_url`, so this is a no-op outside of tests.
  defp base_url do
    Application.get_env(:sleeper_player_api, :fantasy_calc_base_url, @fantasy_calc_url)
  end

  # Same reasoning as `Sleeper.process_response_body/1`: left raw here so
  # `get/1` can decode with the status code in hand.
  def process_response_body(body), do: body

  @doc """
  `GET /values/current?isDynasty=true&numQbs=2&numTeams=12&ppr=1` — the one
  endpoint this client calls, per plan §2. Query params are fixed (dynasty,
  2-QB, 12-team, full PPR) rather than parameterized: nothing in this repo
  needs a different slice of FantasyCalc's values, and pinning them here
  means every caller gets the exact same value set the plan measured
  against.

  Returns:

    * `{:ok, decoded_body}` on a 2xx response with a JSON body — a bare
      list of value entries (not wrapped in an envelope), per the verified
      response shape in the plan.
    * `{:error, {:http_error, status_code}}` on any non-2xx status
    * `{:error, {:invalid_json, status_code}}` on a 2xx response whose body
      isn't valid JSON
    * `{:error, {:transport_error, reason}}` on a connection failure
  """
  def get(
        url \\ "/values/current?isDynasty=true&numQbs=2&numTeams=12&ppr=1",
        headers \\ [],
        options \\ []
      ) do
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
end
