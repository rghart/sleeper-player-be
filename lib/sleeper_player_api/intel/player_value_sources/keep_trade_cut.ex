defmodule SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCut do
  @moduledoc """
  The `SleeperPlayerApi.Intel.PlayerValueSource` implementation for
  KeepTradeCut.

  All shaping lives here; `SleeperPlayerApi.Client.KeepTradeCut` only knows
  how to fetch the page and pull the array out of it — the same split as
  `PlayerValueSources.FantasyCalc` vs `Client.FantasyCalc`.

  **This is an additional source, never a replacement.** FantasyCalc stays
  the configured `:player_value_source` because `Intel.Estimator` is
  calibrated against that exact slice (dynasty superflex 12-team full PPR),
  and `Intel.Calibration` would have to be re-run against a new baseline
  before any of that could move. Swapping the default here would silently
  re-base the availability model.

  **One fetch yields two sources.** KTC prices 1QB and superflex separately
  and ships both in the same payload, so `fetch_values/0` returns entries
  under two `source` values rather than making the caller fetch twice:

    * `#{inspect("keeptradecut:1qb")}`
    * `#{inspect("keeptradecut:sf")}`

  `player_values` is keyed `(player_id, source)`, so the two coexist without
  either clobbering the other, and a caller asks for the one matching their
  league — which the frontend already knows how to determine, since
  `leagueMarketSettings` reads `numQbs` off the Sleeper league object.

  **Rookie draft picks are dropped, deliberately and visibly.** 36 of the 500
  entries are picks (`2027 Early 1st`), which are not players.
  `player_values.player_id` is a Sleeper player id, so they have no home
  here. Pricing picks is a real gap worth closing — the app already tracks
  traded picks end to end and has never been able to value them — but it
  needs its own table, not a fake player id.

  Picks are marked by **`mflid: 0`, not by a missing field** (verified
  2026-08-12: all 36, and no entry in the payload omits `mflid`). Zero is
  rejected explicitly rather than left to fail the crosswalk lookup on its
  own — no row in the crosswalk is keyed `0` today, so the lookup does drop
  them, but that is a property of somebody else's file rather than a decision
  this module made.

  **`roster_percent` and `trade_frequency` stay `nil`.** KTC carries
  `kept`/`traded`/`cut` counts and its own liquidity figures, none of which
  are the same measurement as FantasyCalc's two fields. Mapping one onto the
  other would make two sources look comparable on a column where they are
  not.
  """

  @behaviour SleeperPlayerApi.Intel.PlayerValueSource

  require Logger

  alias SleeperPlayerApi.Client.KeepTradeCut, as: Client
  alias SleeperPlayerApi.Intel.PlayerIdCrosswalk

  @source "keeptradecut"
  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  @doc """
  The provider family name, used for logging.

  Note this is *not* what lands in `player_values.source` — entries carry
  `#{inspect(@one_qb)}` or `#{inspect(@superflex)}`, since one fetch produces
  both. The behaviour's `name/0` is a single string and the variants are a
  property of the entries, so this returns the family.
  """
  @impl true
  def name, do: @source

  @impl true
  def fetch_values do
    with {:ok, players} <- Client.get_rankings(),
         {:ok, crosswalk} <- PlayerIdCrosswalk.mfl_to_sleeper() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      entries = Enum.flat_map(players, &shape_player(&1, crosswalk, now))

      case entries do
        [] ->
          # Every player failing to join is not a quiet no-op: it is what a
          # broken crosswalk, a renamed field or an error page served with a
          # 200 all look like, and upserting nothing would leave the last
          # good values in place with no signal that anything went wrong.
          {:error, :no_joinable_players}

        entries ->
          log_coverage(players, entries)
          {:ok, entries}
      end
    end
  end

  # Both variants for one player, or `[]` if he cannot be joined to a Sleeper
  # id at all. `flat_map` over `[]`/`[entry]` drops an unjoinable row without
  # failing the whole fetch, same as the FantasyCalc source does for a
  # missing `sleeperId`.
  defp shape_player(player, crosswalk, now) do
    with mfl_id when not is_nil(mfl_id) <- to_id_string(player["mflid"]),
         sleeper_id when not is_nil(sleeper_id) <- Map.get(crosswalk, mfl_id),
         {player_id, ""} <- Integer.parse(sleeper_id) do
      [
        entry(player_id, @one_qb, player["oneQBValues"], player, now),
        entry(player_id, @superflex, player["superflexValues"], player, now)
      ]
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp entry(_player_id, _source, nil, _player, _now), do: nil

  defp entry(player_id, source, values, player, now) do
    %{
      player_id: player_id,
      source: source,
      value: to_float(values["value"]),
      overall_rank: values["rank"],
      position_rank: values["positionalRank"],
      # See the moduledoc: KTC's liquidity figures are a different
      # measurement, not these two under another name.
      roster_percent: nil,
      trade_frequency: nil,
      draft_year: player["draftYear"],
      as_of: now
    }
  end

  # The payload's ids arrive as integers; the crosswalk is keyed by string.
  # Normalising here rather than at every call site is what stops a
  # `1924`/`"1924"` mismatch dropping a player silently.
  #
  # `0` is KTC's "not a player" sentinel, carried by every draft-pick entry.
  # See the moduledoc: it is refused here rather than relying on the
  # crosswalk having no row for it.
  defp to_id_string(nil), do: nil
  defp to_id_string(0), do: nil
  defp to_id_string("0"), do: nil
  defp to_id_string(id) when is_integer(id), do: Integer.to_string(id)

  defp to_id_string(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {_int, ""} -> String.trim(id)
      _ -> nil
    end
  end

  defp to_id_string(_), do: nil

  defp to_float(nil), do: nil
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: nil

  # Coverage is logged rather than asserted. The draft-pick entries make a
  # bare "shaped N of M" read alarming when nothing is wrong, so the two
  # reasons an entry can be missing are counted separately — a rising
  # `unjoined` is a real problem, a steady `picks` is the known gap.
  defp log_coverage(players, entries) do
    picks = Enum.count(players, &is_nil(to_id_string(&1["mflid"])))
    joined = div(length(entries), 2)
    unjoined = length(players) - picks - joined

    Logger.info(
      "KeepTradeCut: #{joined} players joined, #{unjoined} unjoined, #{picks} draft picks skipped"
    )
  end
end
