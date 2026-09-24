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

  # Where each variable's data lives. Since 2026-09-08 KTC no longer writes
  # the JSON into the script itself: the page carries it in a
  # `<script type="application/json" id="...">` block and the script reads it
  # back with `JSON.parse(document.getElementById(id).textContent)`. The
  # hourly refresh failed with `:players_array_not_found` for 16 days before
  # anyone noticed, because nothing but a log line said so.
  @json_blocks %{
    "playersArray" => "ktc-players",
    "playerOneQB" => "pd-oneqb",
    "playerSuperflex" => "pd-superflex"
  }

  # The pre-2026-09-08 shape, kept as a fallback: a site that has changed its
  # markup once may well change it back, and reading both costs nothing.
  #
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
    * `{:error, :players_array_not_found}` when the page carries neither the
      `ktc-players` JSON block nor the older inline `var playersArray` (a site
      redesign, or an error page served with a 200)
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

  @doc """
  `GET /dynasty-rankings/players/:slug`, returning that player's value
  history under both variants as `{:ok, %{one_qb: map, superflex: map}}`.

  This is the only place KTC publishes a time series. The rankings page
  carries `history: []` for every player; the *player* page embeds
  `var playerOneQB` and `var playerSuperflex`, each with `overallValue`,
  `overallRankHistory` and `positionalRankHistory` — daily points back to
  2023-03-10.

  Each page is ~3.5MB, because it re-embeds the full rankings array
  alongside the one player's history. That is why this belongs to a one-shot
  paced backfill and never to the hourly refresh: the whole board costs one
  1.3MB request through `get_rankings/0`, and the whole board's *history*
  costs ~465 requests and ~1.6GB.

  A variant that is missing or does not decode comes back absent from the map
  rather than failing the page — one variant is still worth backfilling.
  `{:error, :player_not_found}` when neither is present, which is what a bad
  slug or a redesign looks like.
  """
  @spec get_player_history(String.t()) :: {:ok, map} | {:error, term}
  def get_player_history(slug) do
    case get("/dynasty-rankings/players/#{slug}", [], recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        variants =
          %{one_qb: "playerOneQB", superflex: "playerSuperflex"}
          |> Enum.flat_map(fn {key, var} ->
            case extract_object(body, var) do
              {:ok, object} -> [{key, object}]
              :error -> []
            end
          end)
          |> Map.new()

        if map_size(variants) == 0, do: {:error, :player_not_found}, else: {:ok, variants}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:transport_error, reason}}
    end
  end

  # Anchored on `};` at end of line rather than on brace balancing: these are
  # machine-emitted one-per-line literals, and a balanced-brace scan over a
  # 3.5MB page to gain nothing measurable is not worth the code.
  defp extract_object(body, var) do
    with [json] <- json_block(body, var) || legacy_object(body, var),
         {:ok, object} when is_map(object) <- Jason.decode(json) do
      {:ok, object}
    else
      _ -> :error
    end
  end

  defp legacy_object(body, var),
    do: Regex.run(~r/var #{var}\s*=\s*(\{.*?\});\s*$/ms, body, capture: :all_but_first)

  # The JSON inside `<script type="application/json" id="...">` for a
  # variable, or nil when the page has no such block. Matched on the id alone
  # so attribute order and extra attributes do not matter.
  defp json_block(body, var) do
    id = Map.fetch!(@json_blocks, var)
    Regex.run(~r/<script\b[^>]*\bid="#{id}"[^>]*>(.*?)<\/script>/s, body, capture: :all_but_first)
  end

  defp extract_players(body) do
    case json_block(body, "playersArray") ||
           Regex.run(@players_array, body, capture: :all_but_first) do
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
