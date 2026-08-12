defmodule SleeperPlayerApi.Client.KeepTradeCut do
  @moduledoc """
  Thin HTTPoison wrapper around KeepTradeCut's dynasty rankings page, same
  shape as `SleeperPlayerApi.Client.FantasyCalc`: `use HTTPoison.Base`, a
  non-raising `get_rankings/0` returning tagged tuples, and the base URL read
  from Application env so tests can point it at Bypass.

  **On the terms of service.** `docs/leaguemate-intel.md` §2 records KTC as
  off-limits, quoting their prohibition on automated collection, and that is
  why FantasyCalc was chosen. Ryan has since obtained permission from the
  site to fetch this data for his own use (2026-08-12); §2 has been updated
  to say so. Without that permission this module should not exist, and the
  reasoning in §2 stands for anyone else reading it.

  There is no KTC API — the values are embedded in the HTML of
  `/dynasty-rankings` as `var playersArray = [...]`, so this client fetches a
  page and pulls one JSON literal out of it. That is a more brittle contract
  than an API, which is why `{:error, :players_array_not_found}` is a
  first-class outcome rather than a crash: a markup change should fail the
  refresh loudly and leave the last good values in place, per
  `RefreshPlayerValues`' existing "nothing is upserted on a failed fetch"
  contract.
  """

  use HTTPoison.Base

  @keep_trade_cut_url "https://keeptradecut.com"

  # `.*?` is non-greedy and `s` makes `.` match newlines: the literal is one
  # ~1.2MB line in practice, but anchoring on the first `];` rather than the
  # last is what keeps this from swallowing the rest of the document if the
  # page ever carries a second array after it.
  @players_array ~r/var playersArray\s*=\s*(\[.*?\]);/s

  def process_request_url(url), do: base_url() <> url

  defp base_url do
    Application.get_env(:sleeper_player_api, :keep_trade_cut_base_url, @keep_trade_cut_url)
  end

  def process_response_body(body), do: body

  @doc """
  `GET /dynasty-rankings`, returning the decoded `playersArray`.

  Returns:

    * `{:ok, players}` — a list of player maps, each carrying `oneQBValues`
      and `superflexValues`
    * `{:error, {:http_error, status}}` on any non-2xx
    * `{:error, :players_array_not_found}` when the page no longer embeds the
      array (a site redesign, or an error page served with a 200)
    * `{:error, {:invalid_json, :players_array}}` when it is there but does
      not decode
    * `{:error, {:transport_error, reason}}` on a connection failure
  """
  @spec get_rankings() :: {:ok, [map]} | {:error, term}
  def get_rankings do
    case get("/dynasty-rankings", [], recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        extract_players(body)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp extract_players(body) do
    case Regex.run(@players_array, body, capture: :all_but_first) do
      [json] ->
        case Jason.decode(json) do
          {:ok, players} when is_list(players) -> {:ok, players}
          {:ok, _not_a_list} -> {:error, {:invalid_json, :players_array}}
          {:error, _reason} -> {:error, {:invalid_json, :players_array}}
        end

      nil ->
        {:error, :players_array_not_found}
    end
  end
end
