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

  KTC's liquidity is now stored — in its own `liquidity` column, which is the
  point. It sits beside `trade_frequency` rather than inside it, so a caller
  reading either knows which provider's measurement it has.

  **Three fields beyond value, added 2026-08-15**: `liquidity`
  (`stdLiquidity`, per-format), `injury_return` and `bye_week` (both
  per-player, so identical on the two format rows). Injury *status* is
  deliberately not among them — Sleeper's own dump has carried it all along.
  See the migration for the measurements behind both decisions.
  """

  @behaviour SleeperPlayerApi.Intel.PlayerValueSource

  require Logger

  alias SleeperPlayerApi.Client.KeepTradeCut, as: Client
  alias SleeperPlayerApi.Intel.PlayerIdCrosswalk

  @source "keeptradecut"
  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  # KTC's three TE-premium tiers, as its payload names them. Each format's
  # values carry all three, and only tight ends' differ from the base value
  # (checked 2026-10-01: Brock Bowers 8,040 base, 8,897 / 9,722 / 9,999; every
  # other position identical across tiers). See `MarketSettings.ktc_tep_level/1`
  # for which tier a league gets.
  @tep_levels ~w(tep tepp teppp)

  # KTC's three value bases, and the keys each is read from. "crowd" is its
  # crowdsourced value, what this app has always stored under the plain
  # source names; "trades" is its value from real trades (`vft`); "blend" is
  # KTC's own mix of the two. Checked 2026-10-01: every player, pick and TE
  # tier carries all three, and they differ most on picks (a 2027 early 1st
  # at 7,089 crowdsourced, 5,895 from trades).
  @bases %{
    "crowd" => {"value", "rank", "positionalRank"},
    "trades" => {"vftValue", "vftRank", "vftPositionalRank"},
    "blend" => {"blendValue", "blendRank", "blendPositionalRank"}
  }

  @doc "KTC's TE-premium tiers, mildest first."
  def tep_levels, do: @tep_levels

  @doc "KTC's value bases: crowd, trades, blend."
  def bases, do: Map.keys(@bases) |> Enum.sort()

  @doc """
  The source a value basis is stored under. Crowdsourced keeps the plain
  name (`keeptradecut:sf`), so everything that read KTC before reads exactly
  what it did; the others add the basis (`keeptradecut:sf:blend`).
  """
  def basis_source(format_source, "crowd"), do: format_source

  def basis_source(format_source, basis) when is_map_key(@bases, basis),
    do: "#{format_source}:#{basis}"

  @doc """
  Whether a source is a variant (a TE tier or a non-crowd basis) rather than
  one of the two crowdsourced lists. Variants are current values only.
  """
  def variant_source?(source) when is_binary(source),
    do: tep_source?(source) or String.contains?(source, [":trades", ":blend"])

  @doc "The source a TE-premium tier is stored under: `keeptradecut:sf:tep`."
  def tep_source(base, level) when level in @tep_levels, do: "#{base}:#{level}"

  @doc "Whether a source is a TE-premium variant rather than a base list."
  def tep_source?(source) when is_binary(source),
    do: Enum.any?(@tep_levels, &String.ends_with?(source, ":" <> &1))

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
      shape_players(players, crosswalk, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end

  @doc """
  The pure half of `fetch_values/0`: a fetched payload and crosswalk shaped
  into value entries.

  Split out so `Tasks.RefreshKtcValues` can shape players and picks from one
  fetch instead of requesting the same 1.3MB page twice.
  """
  @spec shape_players([map], map, DateTime.t()) :: {:ok, [map]} | {:error, :no_joinable_players}
  def shape_players(players, crosswalk, now) do
    case Enum.flat_map(players, &shape_player(&1, crosswalk, now)) do
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

  @doc """
  The rookie draft picks in the same payload, shaped for `draft_pick_values`.

  Separate from `fetch_values/0` because they go to a different table — a pick
  is not a player and `player_values.player_id` is a Sleeper player id. The
  caller fetches once and writes both; see `Tasks.RefreshKtcValues`.

  Both variants per pick, same as players. Two namings are read:

    * `"2027 Early 1st"` - a pick whose slot is not known yet, stored with
      tier `"early"` / `"mid"` / `"late"`.
    * `"2027 Pick 1.04"` - an exact slot, which KTC lists once a season is
      over and draft orders are set. Stored with tier `"slot-4"`: the pick
      number within the round, in the same column, so exact slots need no
      migration and a caller that knows its slot asks for it the same way.

  Anything else is dropped rather than guessed at - an unparseable pick means
  the naming changed, which should show up as missing rather than as a wrong
  price. `unrecognized_picks/1` names what was dropped so the refresh can
  say so out loud.
  """
  @spec pick_entries([map], DateTime.t()) :: [map]
  def pick_entries(players, now) do
    Enum.flat_map(players, fn player ->
      case parse_pick(player["playerName"]) do
        {:ok, {season, tier, round}} ->
          for {format, key} <- [{@one_qb, "oneQBValues"}, {@superflex, "superflexValues"}],
              basis <- bases(),
              is_map(player[key]),
              is_number(player[key][elem(@bases[basis], 0)]) do
            values = player[key]
            {value_key, rank_key, position_rank_key} = @bases[basis]

            %{
              season: season,
              round: round,
              tier: tier,
              source: basis_source(format, basis),
              value: to_float(values[value_key]),
              overall_rank: values[rank_key],
              position_rank: values[position_rank_key],
              as_of: now
            }
          end

        :error ->
          []
      end
    end)
  end

  # "2027 Early 1st" -> {2027, "early", 1}. The ordinal suffix is not
  # validated against the number (no "1th" check): it is decoration on a value
  # already captured, and rejecting a well-formed round over its suffix would
  # lose a real price.
  @pick_name ~r/^(\d{4})\s+(Early|Mid|Late)\s+(\d+)(?:st|nd|rd|th)$/i

  # "2027 Pick 1.04" -> {2027, "slot-4", 1}. Deliberately read from the name
  # and not from the payload's `pickRound` / `pickNum`: those are 0 on every
  # tiered pick today, and nothing observed yet says whether `pickNum` counts
  # within the round or across the draft. A guess there would be a wrong price
  # that looks right; an unmatched name is a push notification instead.
  @slot_name ~r/^(\d{4})\s+Pick\s+(\d+)\.(\d+)$/i

  @doc """
  KTC entries marked as rookie picks (`position: "RDP"`) that neither pick
  naming matches - the values `pick_entries/2` is dropping. Each comes back
  with the fields a fix would need.
  """
  @spec unrecognized_picks([map]) :: [map]
  def unrecognized_picks(players) do
    players
    |> Enum.filter(&(&1["position"] == "RDP" and parse_pick(&1["playerName"]) == :error))
    |> Enum.map(&Map.take(&1, ["playerName", "pickRound", "pickNum", "draftYear"]))
  end

  defp parse_pick(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      match = Regex.run(@pick_name, name, capture: :all_but_first) ->
        [season, tier, round] = match
        {:ok, {String.to_integer(season), String.downcase(tier), String.to_integer(round)}}

      match = Regex.run(@slot_name, name, capture: :all_but_first) ->
        [season, round, slot] = match

        {:ok,
         {String.to_integer(season), "slot-#{String.to_integer(slot)}", String.to_integer(round)}}

      true ->
        :error
    end
  end

  defp parse_pick(_), do: :error

  # Both variants for one player, or `[]` if he cannot be joined to a Sleeper
  # id at all. `flat_map` over `[]`/`[entry]` drops an unjoinable row without
  # failing the whole fetch, same as the FantasyCalc source does for a
  # missing `sleeperId`.
  defp shape_player(player, crosswalk, now) do
    with mfl_id when not is_nil(mfl_id) <- to_id_string(player["mflid"]),
         sleeper_id when not is_nil(sleeper_id) <- Map.get(crosswalk, mfl_id),
         {player_id, ""} <- Integer.parse(sleeper_id) do
      (for {format, key} <- [{@one_qb, "oneQBValues"}, {@superflex, "superflexValues"}],
           basis <- bases() do
         entry(player_id, basis_source(format, basis), player[key], player, now, basis)
       end ++ tep_entries(player_id, player, now))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # A tight end's value under each TE-premium tier, for both formats. Only
  # tight ends: every other position's tiered value is its base value, so
  # storing them would multiply the table for nothing. A lookup lays these
  # over the base list (`Intel.player_values_with_tep/2`).
  defp tep_entries(player_id, %{"position" => "TE"} = player, now) do
    for {format, key} <- [{@one_qb, "oneQBValues"}, {@superflex, "superflexValues"}],
        basis <- bases(),
        level <- @tep_levels,
        is_map(get_in(player, [key, level])) do
      source = format |> basis_source(basis) |> tep_source(level)
      entry(player_id, source, get_in(player, [key, level]), player, now, basis)
    end
  end

  defp tep_entries(_player_id, _player, _now), do: []

  defp entry(_player_id, _source, nil, _player, _now, _basis), do: nil

  defp entry(player_id, source, values, player, now, basis) do
    {value_key, rank_key, position_rank_key} = @bases[basis]

    # A basis KTC does not send for this entry is no row at all, not a row
    # with no value: an older payload, or one missing the trade-based figure,
    # stores exactly the crowdsourced rows it always did.
    if is_number(values[value_key]),
      do:
        entry_row(
          player_id,
          source,
          values,
          player,
          now,
          {value_key, rank_key, position_rank_key}
        )
  end

  defp entry_row(player_id, source, values, player, now, {value_key, rank_key, position_rank_key}) do
    %{
      player_id: player_id,
      source: source,
      value: to_float(values[value_key]),
      overall_rank: values[rank_key],
      position_rank: values[position_rank_key],
      # See the moduledoc: KTC's liquidity figures are a different
      # measurement, not these two under another name.
      roster_percent: nil,
      trade_frequency: nil,
      draft_year: player["draftYear"],
      # Per-format: KTC prices liquidity separately for 1QB and superflex, so
      # it belongs on this row rather than beside the per-player fields below.
      liquidity: to_float(values["stdLiquidity"]),
      # Per-player, so identical on both format rows. See the migration for
      # why that duplication was preferred to a second writer into `players`.
      injury_return: parse_return_date(player["injury"]),
      bye_week: player["byeWeek"],
      as_of: now
    }
  end

  # KTC dates its expected returns as "Aug 22, 2026". Parsed to a real date so
  # a return already in the past reads differently from one still ahead; an
  # unparseable value is dropped rather than guessed at, the same rule
  # `parse_pick/1` follows.
  #
  # The healthy majority carry `%{"injuryCode" => 1}` and no other key —
  # measured 2026-08-15, 425 of 500 — so a missing `injuryReturn` is the
  # normal case, not a failure.
  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @return_date ~r/^([A-Za-z]{3})[a-z]*\s+(\d{1,2}),\s*(\d{4})$/

  defp parse_return_date(%{"injuryReturn" => date}) when is_binary(date) do
    with [month, day, year] <-
           Regex.run(@return_date, String.trim(date), capture: :all_but_first),
         month when not is_nil(month) <- @months[String.downcase(month)],
         {:ok, parsed} <- Date.new(String.to_integer(year), month, String.to_integer(day)) do
      parsed
    else
      _ -> nil
    end
  end

  defp parse_return_date(_), do: nil

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
