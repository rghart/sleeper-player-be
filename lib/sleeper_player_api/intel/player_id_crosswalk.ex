defmodule SleeperPlayerApi.Intel.PlayerIdCrosswalk do
  @moduledoc """
  MyFantasyLeague id → Sleeper id, from DynastyProcess' published id map.

  KeepTradeCut keys on its own `playerID` and carries `mflid`, but never a
  Sleeper id — which is the one thing every table in this codebase is keyed
  by, and the entire reason `docs/leaguemate-intel.md` §2 preferred
  FantasyCalc (it hands `sleeperId` over for free). This module is the bridge
  that makes a KTC value joinable.

  **`mfl_id` is the join key, not `ktc_id`, which is the opposite of what the
  plan assumed.** §2 says "if you ever obtain KTC values legitimately, the
  join key is already published for you", meaning `ktc_id`. Measured
  2026-08-12 against the live payload and the current crosswalk, over the 464
  non-pick entries:

      joined via mfl_id : 461 (99.4%)
      joined via ktc_id : 452 (97.4%)
      either            : 461 (99.4%)
      disagreements     : 0 of 452

  `ktc_id` resolves to a Sleeper id for only 459 crosswalk rows against
  `mfl_id`'s 6,362, so the obvious-looking key is the sparse one and adds
  nothing `mfl_id` does not already cover. Both paths agreeing everywhere
  they overlap is why `ktc_id` is worth keeping as a cross-check rather than
  as the primary.

  **The three that do not join are 2026 rookies** — CJ Daniels, Matthew
  Hibner, Le'Veon Moss — all in the crosswalk's newest id range, where it has
  simply not caught up yet. Expect this number to be small, non-zero, and
  concentrated in the most recent class; a jump in it means the crosswalk
  went stale, which is what the value source's coverage log is for.

  **A caution about measuring this.** The first pass at these figures
  reported 100% because it treated the literal string `NA` — which is how
  this file spells "no id" — as a valid Sleeper id. Roughly half the rows
  carry `NA`, so the inflated crosswalk (12,470 "pairs") joined everything
  and meant nothing. Any recount must reject `NA` explicitly, as `numeric/1`
  below does.

  The 36 entries KTC marks with `mflid: 0` are rookie draft picks
  (`2027 Early 1st` and friends), which have no player id by nature. They are
  not a coverage gap in this map — they need a home of their own, and until
  they have one they are dropped by the value source rather than guessed at.
  """

  require Logger

  alias SleeperPlayerApi.Intel.MarketValuesCache

  @crosswalk_url "https://raw.githubusercontent.com/dynastyprocess/data/master/files/db_playerids.csv"

  # Reuses the existing TTL cache rather than adding a second one. The key is
  # namespaced so it cannot collide with a market-values query string.
  @cache_key "player_id_crosswalk:mfl_to_sleeper"

  @doc """
  `%{mfl_id => sleeper_id}`, both as strings, cached.

  Strings on both sides deliberately. Sleeper ids are compared and stored as
  integers elsewhere, but the *lookup* is against a value read out of
  someone else's JSON, and normalising both sides to a string is what stops a
  `1924` / `"1924"` mismatch silently dropping a player. The caller parses to
  an integer once, after the join succeeds.

  On a fetch failure this returns `{:error, reason}` rather than an empty
  map: an empty crosswalk would join nothing, and a value source that
  silently stored zero rows looks identical to one whose provider went quiet.
  """
  @spec mfl_to_sleeper() :: {:ok, %{String.t() => String.t()}} | {:error, term}
  def mfl_to_sleeper do
    case MarketValuesCache.get(@cache_key) do
      {:ok, map} ->
        {:ok, map}

      :miss ->
        with {:ok, csv} <- fetch() do
          map = parse(csv)
          Logger.info("PlayerIdCrosswalk: loaded #{map_size(map)} mfl→sleeper pairs")
          MarketValuesCache.put(@cache_key, map)
          {:ok, map}
        end
    end
  end

  defp fetch do
    case HTTPoison.get(crosswalk_url(), [], recv_timeout: 30_000, follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp crosswalk_url do
    Application.get_env(:sleeper_player_api, :player_id_crosswalk_url, @crosswalk_url)
  end

  @doc """
  Parses the crosswalk CSV into `%{mfl_id => sleeper_id}`.

  Public for the tests, which is the only reason it isn't private.

  **Split on commas, with no CSV library, and that is safe here for a
  specific reason rather than by luck.** The file does contain quoted fields
  — one row is `"Bennett,Michael"` — but every quotable field is a *name*,
  and the two columns this reads (`mfl_id` at 0, `sleeper_id` at 5) both sit
  ahead of the first name column at 20. A comma inside a name cannot shift a
  field this function reads. Column positions are resolved from the header
  rather than hardcoded, so a reordered file is handled rather than silently
  misread, and rows whose ids do not parse as integers are skipped — which is
  also what catches the `NA` this file uses for "no id".
  """
  @spec parse(String.t()) :: %{String.t() => String.t()}
  def parse(csv) do
    [header | rows] = String.split(csv, ~r/\r?\n/, trim: true)
    columns = String.split(header, ",")

    with mfl when not is_nil(mfl) <- Enum.find_index(columns, &(&1 == "mfl_id")),
         sleeper when not is_nil(sleeper) <- Enum.find_index(columns, &(&1 == "sleeper_id")) do
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        fields = String.split(row, ",")

        case {numeric(Enum.at(fields, mfl)), numeric(Enum.at(fields, sleeper))} do
          {nil, _} -> acc
          {_, nil} -> acc
          {mfl_id, sleeper_id} -> Map.put(acc, mfl_id, sleeper_id)
        end
      end)
    else
      # A file with no `mfl_id`/`sleeper_id` header is not a crosswalk. An
      # empty map is the honest answer, and the caller's zero-join guard
      # turns it into a loud failure rather than a quiet no-op.
      nil -> %{}
    end
  end

  # Keeps the string, but only once it is known to be a number — so `NA`,
  # blanks and stray text are all dropped by the same rule.
  defp numeric(nil), do: nil

  defp numeric(field) do
    trimmed = String.trim(field)

    case Integer.parse(trimmed) do
      {_int, ""} -> trimmed
      _ -> nil
    end
  end
end
