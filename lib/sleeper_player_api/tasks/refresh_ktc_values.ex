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

  @doc """
  Fetches once and writes current player values, their daily close, and pick
  values.

  Returns `{:ok, %{values: n, history: n, picks: n}}`, or `{:error, reason}`
  with nothing written — the same all-or-nothing contract
  `RefreshPlayerValues` has, so a bad fetch cannot half-update the board.
  """
  @spec refresh() :: {:ok, map} | {:error, term}
  def refresh do
    with {:ok, players} <- Client.get_rankings(),
         {:ok, crosswalk} <- PlayerIdCrosswalk.mfl_to_sleeper(),
         now = DateTime.utc_now() |> DateTime.truncate(:second),
         {:ok, entries} <- KeepTradeCut.shape_players(players, crosswalk, now) do
      picks = KeepTradeCut.pick_entries(players, now)

      {values, _} = Intel.upsert_player_values(entries)
      {history, _} = Intel.record_value_history(entries)
      {stored_picks, _} = Intel.upsert_draft_pick_values(picks)

      Logger.info(
        "RefreshKtcValues: #{values} values, #{history} history rows, #{stored_picks} pick values"
      )

      {:ok, %{values: values, history: history, picks: stored_picks}}
    else
      {:error, reason} = error ->
        Logger.error("RefreshKtcValues: #{inspect(reason)}")
        error
    end
  end
end
