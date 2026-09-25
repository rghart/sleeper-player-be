defmodule SleeperPlayerApi.Tasks.RefreshKtcValues do
  @moduledoc """
  The hourly KeepTradeCut refresh: one fetch, three writes.

  KTC ships players and rookie draft picks in the same payload, and they land
  in different tables — `player_values` (plus its history) and
  `draft_pick_values`. This exists so that costs one request rather than two.

  `RefreshPlayerValues` stays the generic, source-agnostic task and still
  drives FantasyCalc nightly; it cannot do this job because
  `PlayerValueSource.fetch_values/0` returns player entries and knows nothing
  about picks. Rather than widen that behaviour for one source's extra table,
  the KTC-specific orchestration lives here.
  """

  require Logger

  alias SleeperPlayerApi.Client.KeepTradeCut, as: Client
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.PlayerIdCrosswalk
  alias SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCut
  alias SleeperPlayerApi.Repo

  @doc """
  Fetches once and writes current player values, their daily close, and pick
  values, pruning any pick the fetch no longer lists.

  Returns `{:ok, %{values: n, history: n, picks: n, pruned_picks: n}}`, or
  `{:error, reason}` with nothing written — the same all-or-nothing contract
  `RefreshPlayerValues` has, so a bad fetch cannot half-update the board. The
  writes share one transaction so that holds past the fetch too: the prune
  deletes rows, and must never land without the upsert it is measured against.
  """
  @spec refresh() :: {:ok, map} | {:error, term}
  def refresh do
    with {:ok, players} <- Client.get_rankings(),
         {:ok, crosswalk} <- PlayerIdCrosswalk.mfl_to_sleeper(),
         now = DateTime.utc_now() |> DateTime.truncate(:second),
         {:ok, entries} <- KeepTradeCut.shape_players(players, crosswalk, now),
         picks = KeepTradeCut.pick_entries(players, now),
         {:ok, counts} <- Repo.transaction(fn -> write(entries, picks) end) do
      Logger.info(
        "RefreshKtcValues: #{counts.values} values, #{counts.history} history rows, " <>
          "#{counts.picks} pick values, #{counts.pruned_picks} stale picks pruned"
      )

      if picks == [], do: Logger.warning("RefreshKtcValues: no picks parsed; kept the last ones")

      {:ok, counts}
    else
      {:error, reason} = error ->
        Logger.error("RefreshKtcValues: #{inspect(reason)}")
        error
    end
  end

  defp write(entries, picks) do
    {values, _} = Intel.upsert_player_values(entries)
    {history, _} = Intel.record_value_history(entries)
    {stored_picks, _} = Intel.upsert_draft_pick_values(picks)
    {pruned, _} = Intel.prune_draft_pick_values(picks)

    %{values: values, history: history, picks: stored_picks, pruned_picks: pruned}
  end
end
