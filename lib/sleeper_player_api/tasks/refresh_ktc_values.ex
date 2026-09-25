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

  alias SleeperPlayerApi.Alerts
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

      alert_unrecognized_picks(KeepTradeCut.unrecognized_picks(players), now)

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

  # KTC listing a pick this app cannot read means its value is silently
  # dropped - exactly how the exact-slot picks KTC adds after each season
  # would first arrive if their naming is not the one guessed at. Pushed at
  # most once a day, with the fields a fix needs, rather than left in a log.
  @unrecognized_key {__MODULE__, :unrecognized_picks_alerted_at}

  defp alert_unrecognized_picks([], _now), do: :ok

  defp alert_unrecognized_picks(unrecognized, now) do
    last = :persistent_term.get(@unrecognized_key, nil)

    if last == nil or DateTime.diff(now, last, :hour) >= 24 do
      examples =
        unrecognized
        |> Enum.take(3)
        |> Enum.map_join("; ", fn pick ->
          "#{inspect(pick["playerName"])} (pickRound #{pick["pickRound"]}, pickNum #{pick["pickNum"]})"
        end)

      Alerts.push(
        "KTC lists #{length(unrecognized)} picks the app can't read",
        "Their values are being dropped. Examples: #{examples}. " <>
          "Update the pick naming in KeepTradeCut.pick_entries.",
        priority: "high",
        tags: ["warning"]
      )

      :persistent_term.put(@unrecognized_key, now)
    end

    Logger.warning("RefreshKtcValues: #{length(unrecognized)} unrecognized picks dropped")
  end

  @doc false
  def reset_alerts, do: :persistent_term.erase(@unrecognized_key)
end
