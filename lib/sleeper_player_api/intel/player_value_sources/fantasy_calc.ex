defmodule SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalc do
  @moduledoc """
  The `SleeperPlayerApi.Intel.PlayerValueSource` implementation for
  FantasyCalc (plan §2's recommended source — public, no auth,
  `sleeperId`-keyed, carries roster % and trade frequency for free).

  All the shaping lives here, not in the client: `SleeperPlayerApi.Client.FantasyCalc`
  only knows how to make the one HTTP call and decode JSON, same split as
  `Client.Sleeper` vs the modules that call it.
  """

  @behaviour SleeperPlayerApi.Intel.PlayerValueSource

  alias SleeperPlayerApi.Client.FantasyCalc, as: Client
  alias SleeperPlayerApi.Intel.MarketSettings

  @source "fantasycalc"

  @impl true
  def name, do: @source

  @impl true
  def fetch_values, do: fetch_values(MarketSettings.default())

  @doc """
  The same fetch, for a league shape other than the stored one.

  Separate from `fetch_values/0` rather than replacing it: the nightly
  refresh writes exactly one slice and the availability model is calibrated
  against it, so the behaviour callback must keep meaning that slice and
  nothing else. This arity is for a caller asking about *their* league.
  """
  @spec fetch_values(MarketSettings.t()) :: {:ok, [map]} | {:error, term}
  def fetch_values(settings) do
    case Client.get("/values/current?" <> MarketSettings.to_query(settings)) do
      {:ok, entries} when is_list(entries) ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        {:ok, entries |> Enum.flat_map(&shape_entry(&1, now))}

      {:ok, _not_a_list} ->
        {:error, :unexpected_response_shape}

      {:error, _reason} = error ->
        error
    end
  end

  # An entry with no `sleeperId` (or a non-numeric one) can't be joined to
  # our player DB at all — plan §2's whole reason for preferring FantasyCalc
  # over KTC is that it hands us `sleeperId` for free, so an entry without
  # one is simply not usable here. `flat_map` with `[]`/`[entry]` drops it
  # without failing the whole fetch over one bad row.
  defp shape_entry(entry, now) do
    player = entry["player"] || %{}

    case parse_int(player["sleeperId"]) do
      nil ->
        []

      player_id ->
        [
          %{
            player_id: player_id,
            source: @source,
            value: to_float(entry["value"]),
            overall_rank: entry["overallRank"],
            position_rank: entry["positionRank"],
            roster_percent: to_float(entry["maybeRosterPercent"]),
            trade_frequency: to_float(entry["maybeTradeFrequency"]),
            draft_year: get_in(player, ["maybeDraftInfo", "year"]),
            as_of: now
          }
        ]
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp to_float(nil), do: nil
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
end
