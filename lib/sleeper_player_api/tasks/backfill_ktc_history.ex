defmodule SleeperPlayerApi.Tasks.BackfillKtcHistory do
  @moduledoc """
  One-shot backfill of KeepTradeCut's published value history into
  `player_value_history`.

  KTC keeps a daily series per player going back to 2023-03-10 — 1,249 points
  as of 2026-08-12 — which means the history table does not have to
  *accumulate* before it is useful. It can start full.

  **Deliberately not scheduled, and not something to re-run casually.** The
  series is per-player only and each page is ~3.5MB (it re-embeds the whole
  rankings array to show one player's chart), so a full pass is ~465 requests
  and ~1.6GB. The hourly `RefreshPlayerValues` keeps the table current from
  one 1.3MB request; this exists to fill in everything before today.

      SleeperPlayerApi.Tasks.BackfillKtcHistory.backfill()
      SleeperPlayerApi.Tasks.BackfillKtcHistory.backfill(since: ~D[2026-02-12])

  **A narrower `since` does not make it cheaper to fetch**, only cheaper to
  store — the full array arrives in the page either way. Storing everything
  is ~1.16M rows (~175MB); six months is ~167k (~25MB). Both are noise, which
  is why the default keeps the lot: it is already paid for by the time it is
  parsed, and several seasons of it is what distinguishes a normal in-season
  decay from something new.

  **Paced by a plain sleep, not `RateLimiter`.** That limiter is a shared
  bucket sized for Sleeper's documented 1000/min ceiling; borrowing it here
  would have a KTC backfill throttling the draft crawler. This job is
  sequential and one-shot, so an explicit delay between requests is both
  simpler and easier to be a good guest with.

  Rows land through the same `Intel.record_value_history/1` the live refresh
  uses, so a backfilled day and a live day are the same shape. Today's row
  will be written by both; last write wins, and both are the same
  measurement sampled at different moments — verified 2026-08-12, where a
  player page and the rankings array taken hours apart differed by 4 points
  on a 6,000 value.
  """

  require Logger

  alias SleeperPlayerApi.Client.KeepTradeCut, as: Client
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.PlayerIdCrosswalk

  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  # KTC has published daily since 2023-03-10; anything earlier is not a real
  # cutoff, it is "everything".
  @default_since ~D[2000-01-01]

  # 1.5s between pages: ~12 minutes for a full pass, against a site being
  # generous enough to allow this at all. Fast enough to finish in one sitting,
  # slow enough not to look like a scrape.
  @default_delay_ms 1_500

  @doc """
  Backfills every player KTC ranks.

  Options:

    * `:since` — earliest day to store (default: everything)
    * `:delay_ms` — pause between player pages (default: #{@default_delay_ms})
    * `:limit` — stop after N players, for a smoke run before committing to
      the full ~465

  Returns `{:ok, %{players: n, rows: n, failed: n}}`, or `{:error, reason}` if
  the initial rankings or crosswalk fetch fails — those are the two calls that
  make the rest impossible, where an individual player page failing is
  survivable and counted.
  """
  @spec backfill(keyword) :: {:ok, map} | {:error, term}
  def backfill(opts \\ []) do
    since = Keyword.get(opts, :since, @default_since)
    delay = Keyword.get(opts, :delay_ms, @default_delay_ms)

    with {:ok, players} <- Client.get_rankings(),
         {:ok, crosswalk} <- PlayerIdCrosswalk.mfl_to_sleeper() do
      targets = joinable(players, crosswalk) |> take(opts[:limit])

      Logger.info(
        "BackfillKtcHistory: #{length(targets)} players, since #{since}, #{delay}ms apart"
      )

      result =
        targets
        |> Enum.with_index(1)
        |> Enum.reduce(%{players: 0, rows: 0, failed: 0}, fn {{slug, player_id}, index}, acc ->
          # Before the request, not after, so the pacing holds between pages
          # regardless of how long any one of them takes. Skipped on the
          # first so a `limit: 1` smoke run is not gratuitously slow.
          if index > 1, do: Process.sleep(delay)

          case backfill_player(slug, player_id, since) do
            {:ok, rows} ->
              log_progress(index, length(targets), slug, rows)
              %{acc | players: acc.players + 1, rows: acc.rows + rows}

            {:error, reason} ->
              Logger.warning("BackfillKtcHistory: #{slug} failed (#{inspect(reason)})")
              %{acc | failed: acc.failed + 1}
          end
        end)

      Logger.info("BackfillKtcHistory: done — #{inspect(result)}")
      {:ok, result}
    end
  end

  defp backfill_player(slug, player_id, since) do
    with {:ok, variants} <- Client.get_player_history(slug) do
      rows =
        [{:one_qb, @one_qb}, {:superflex, @superflex}]
        |> Enum.flat_map(fn {key, source} ->
          case Map.fetch(variants, key) do
            {:ok, object} -> history_rows(object, player_id, source, since)
            :error -> []
          end
        end)

      {count, _} = Intel.record_value_history(rows)
      {:ok, count}
    end
  end

  @doc """
  One variant's three parallel series, zipped by day into history entries.

  KTC publishes value, overall rank and positional rank as three separate
  arrays of `%{"d" => "YYMMDD", "v" => n}`. They are the same length in
  practice, but they are joined on the date rather than by position: a
  positional zip that silently pairs a value with the wrong day's rank is the
  kind of defect nothing downstream could ever surface.

  Value is the spine — a day with a rank but no value is dropped, since the
  row exists to record a price.

  Nothing here sorts by day, and anything that later does must pass the `Date`
  comparator: `Enum.sort/1` and a bare `sort_by(& &1.day)` fall back to term
  ordering, which compares a `Date` struct field-alphabetically — `day`, then
  `month`, then `year`. A verification script using the bare form reported
  this series as spanning 2024-01-01 to 2025-12-31 when it actually runs
  2023-03-10 to today, and it looked plausible enough to nearly believe.

  Public for the tests.
  """
  @spec history_rows(map, integer, String.t(), Date.t()) :: [map]
  def history_rows(object, player_id, source, since) do
    ranks = by_day(object["overallRankHistory"])
    position_ranks = by_day(object["positionalRankHistory"])

    (object["overallValue"] || [])
    |> Enum.flat_map(fn point ->
      with {:ok, day} <- parse_day(point["d"]),
           true <- Date.compare(day, since) != :lt,
           value when is_number(value) <- point["v"] do
        [
          %{
            player_id: player_id,
            source: source,
            day: day,
            value: value * 1.0,
            overall_rank: Map.get(ranks, day),
            position_rank: Map.get(position_ranks, day),
            # The series carries no timestamp beyond the date. Midnight UTC
            # is a stand-in for "the close of that day", and is what keeps
            # `record_value_history/1` — which derives `day` from `as_of` —
            # putting the row on the day it describes.
            as_of: DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp by_day(nil), do: %{}

  defp by_day(points) do
    Enum.reduce(points, %{}, fn point, acc ->
      case {parse_day(point["d"]), point["v"]} do
        {{:ok, day}, value} when is_integer(value) -> Map.put(acc, day, value)
        _ -> acc
      end
    end)
  end

  # "260812" -> ~D[2026-08-12]. Two-digit years only; KTC's series starts in
  # 2023, so there is no century to disambiguate.
  defp parse_day(<<yy::binary-2, mm::binary-2, dd::binary-2>>) do
    with {year, ""} <- Integer.parse(yy),
         {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd) do
      Date.new(2000 + year, month, day)
    else
      _ -> :error
    end
  end

  defp parse_day(_), do: :error

  # Slug plus the Sleeper id it resolves to. A player who cannot be joined has
  # nowhere to store history, so he is not worth a request.
  defp joinable(players, crosswalk) do
    Enum.flat_map(players, fn player ->
      with slug when is_binary(slug) <- player["slug"],
           mfl_id when mfl_id not in [nil, 0] <- player["mflid"],
           sleeper_id when not is_nil(sleeper_id) <-
             Map.get(crosswalk, to_string(mfl_id)),
           {player_id, ""} <- Integer.parse(sleeper_id) do
        [{slug, player_id}]
      else
        _ -> []
      end
    end)
  end

  defp take(targets, nil), do: targets
  defp take(targets, limit), do: Enum.take(targets, limit)

  # Every 25, so a 465-player run leaves a readable trail without a line per
  # page.
  defp log_progress(index, total, slug, rows) do
    if rem(index, 25) == 0 or index == total do
      Logger.info("BackfillKtcHistory: #{index}/#{total} (#{slug}, #{rows} rows)")
    end
  end
end
