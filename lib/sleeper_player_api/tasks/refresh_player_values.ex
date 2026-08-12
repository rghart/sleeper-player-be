defmodule SleeperPlayerApi.Tasks.RefreshPlayerValues do
  @moduledoc """
  Fetches player values from a `SleeperPlayerApi.Intel.PlayerValueSource`
  and writes them to two places, per plan §3f step 5: `player_values` (the
  current value, upserted in place) and `player_value_history` (that day's
  close, one row per player per source per day).

  Both writes happen in every run, off one shaping pass, so there is no run
  that can update the current value without also recording the series.

  Deliberately NOT wired into the Quantum schedule
  (`config/config.exs`) — scheduling this is a production behaviour change
  that needs separate sign-off. Invoke directly, same as
  `SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts`:

      SleeperPlayerApi.Tasks.RefreshPlayerValues.refresh_player_values()

  Batched `Repo.insert_all`/`on_conflict` throughout (via
  `SleeperPlayerApi.Intel.upsert_player_values/1`) — the one-shot fetch
  makes this a single batch in practice (FantasyCalc's current payload is
  under 500 entries), but it goes through the same batching path as every
  other upsert in this codebase rather than a bespoke per-row loop, which is
  the exact anti-pattern `GetSleeperPlayerData` has and the plan calls out
  not to copy.
  """

  require Logger

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalc

  @doc """
  Fetches every value `source` currently has and upserts them.

  `source` defaults to the configured `SleeperPlayerApi.Intel.PlayerValueSource`
  implementation (`config :sleeper_player_api, :player_value_source`,
  falling back to `PlayerValueSources.FantasyCalc`) — this default, not a
  hardcoded module reference, is the swappable seam plan §2 asks for: making
  KTC (or any other source) the default later is a one-line config change,
  not a call-site change here.

  Returns `{:ok, count}` (rows upserted) or `{:error, reason}` if the
  source's fetch fails — nothing is upserted on a failed fetch, so a bad
  fetch can't partially clobber a good prior refresh.
  """
  @spec refresh_player_values(module) :: {:ok, non_neg_integer} | {:error, term}
  def refresh_player_values(source \\ source_module()) do
    case source.fetch_values() do
      {:ok, entries} ->
        {count, _} = Intel.upsert_player_values(entries)

        # Both writes, every run, from one shaping pass. The current-value
        # table answers "what is he worth"; the history table answers "what
        # has he been worth", and only the second one can support an
        # in-season buy-low/sell-high read. Writing the close here rather
        # than in a separate job is what stops the two drifting apart —
        # there is no run that updates one and not the other.
        {recorded, _} = Intel.record_value_history(entries)

        Logger.info(
          "RefreshPlayerValues: stored #{count} values from #{source.name()}, " <>
            "#{recorded} history rows"
        )

        {:ok, count}

      {:error, reason} = error ->
        Logger.error(
          "RefreshPlayerValues: fetch from #{inspect(source)} failed: #{inspect(reason)}"
        )

        error
    end
  end

  defp source_module do
    Application.get_env(:sleeper_player_api, :player_value_source, FantasyCalc)
  end
end
