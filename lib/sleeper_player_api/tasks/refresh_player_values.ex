defmodule SleeperPlayerApi.Tasks.RefreshPlayerValues do
  @moduledoc """
  Fetches player values from a `SleeperPlayerApi.Intel.PlayerValueSource`
  and upserts them into `player_values`, per plan §3f step 5.

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
        Logger.info("RefreshPlayerValues: stored #{count} values from #{source.name()}")
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
