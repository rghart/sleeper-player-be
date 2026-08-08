defmodule SleeperPlayerApi.Tasks.CrawlLeaguemateTransactions do
  @moduledoc """
  Harvests every transaction — trades, waiver claims, free-agent adds — from
  the leagues your leaguemates are in (plan §6 step 6).

  ## Why a crawl and not an on-demand fetch

  Both were measured before this was written. On-demand fan-out (enumerate a
  manager's leagues, then transactions per league) is cheaper for one or two
  profile views and **cannot dedupe**: 13 leaguemates hold 257 league
  memberships across only 176 unique leagues, so per-profile fetching pays
  that 32% overlap again every time. Viewing all thirteen costs ~527 calls
  against the 300/min bucket `SleeperPlayerApi.RateLimiter` enforces, which
  throttles partway through. The Leaguemates section is a browsing surface —
  tapping through thirteen people is its whole shape — so that is the access
  pattern that matters. Crossover is about three profile views.

  Measured cost of this crawl: 13 enumeration calls + 176 leagues, so **365
  calls cold** (transactions plus roster maps) and **189 nightly** in the
  offseason, roughly 73s and 38s at 300/min.

  ## Which weeks get fetched

  Sleeper buckets **offseason activity into week 1**, and week 1 never
  closes — swept all 18 weeks of a live league and weeks 2–18 were empty. So
  in the offseason there is exactly one week worth fetching and it must be
  refetched every time; there is no immutability to exploit yet.

  In season, a past week is settled and is fetched once, ever. That is what
  `transactions_fetched_through` records — deliberately *not* "the last week
  we fetched", because the current week is still live.

  ## Coverage, not silence

  A league that fails is recorded in `summary.errors` and the crawl carries
  on, same as the draft crawler. What must not happen is a partial harvest
  presented as a complete one: `Intel.transaction_coverage/2` exists so the
  endpoint can say "38 of 42 leagues", and this task's `Summary` is the other
  half of that — `leagues_seen` against `leagues_fetched` tells you whether a
  night's run was whole.
  """

  require Logger

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.ObservedLeague

  defmodule Summary do
    @moduledoc """
    What a run did. `api_calls` is what makes the "a second run makes far
    fewer calls" checkpoint observable rather than asserted.
    """
    defstruct api_calls: 0,
              leaguemates: 0,
              leagues_seen: 0,
              leagues_fetched: 0,
              rosters_fetched: 0,
              weeks_fetched: 0,
              transactions_stored: 0,
              errors: []
  end

  @doc """
  Scheduled entry point. Crawls every league in `:intel_leagues`.

  Never raises: one league erroring must not stop the others, and a crashing
  scheduled job takes its Quantum worker with it.
  """
  @spec crawl_configured_leagues() :: [{term, {:ok, Summary.t()} | {:error, term}}]
  def crawl_configured_leagues do
    leagues = Application.get_env(:sleeper_player_api, :intel_leagues, [])
    season = configured_season()

    if leagues == [] do
      Logger.info("CrawlLeaguemateTransactions: no :intel_leagues configured, nothing to crawl")
      []
    else
      Enum.map(leagues, fn league_id ->
        result =
          try do
            crawl(league_id, season)
          rescue
            e ->
              Logger.error(
                "CrawlLeaguemateTransactions: league #{league_id} raised: #{Exception.message(e)}"
              )

              {:error, {:raised, Exception.message(e)}}
          end

        case result do
          {:ok, summary} ->
            Logger.info(
              "CrawlLeaguemateTransactions: league #{league_id} — " <>
                "#{summary.leagues_fetched}/#{summary.leagues_seen} leagues, " <>
                "#{summary.transactions_stored} transactions, #{summary.api_calls} calls, " <>
                "#{length(summary.errors)} errors"
            )

          {:error, reason} ->
            Logger.error("CrawlLeaguemateTransactions: league #{league_id}: #{inspect(reason)}")
        end

        {league_id, result}
      end)
    end
  end

  defp configured_season do
    case Application.get_env(:sleeper_player_api, :intel_season) do
      nil -> Date.utc_today().year |> Integer.to_string()
      season -> to_string(season)
    end
  end

  @doc """
  Crawls one source league: enumerates its members, then every league each of
  them is in, then those leagues' transactions.

  Returns `{:ok, %Summary{}}` once it has run to completion — a per-league
  failure is recorded in `summary.errors` rather than aborting — or
  `{:error, reason}` if the member enumeration itself fails, since nothing
  can proceed without it.
  """
  @spec crawl(integer | String.t(), String.t()) :: {:ok, Summary.t()} | {:error, term}
  def crawl(league_id, season) do
    summary = %Summary{}

    case request("/league/#{league_id}/users", summary) do
      {{:ok, users}, summary} when is_list(users) ->
        user_ids = users |> Enum.map(& &1["user_id"]) |> Enum.reject(&is_nil/1)
        summary = %{summary | leaguemates: length(user_ids)}

        {leagues, summary} = enumerate_leagues(user_ids, season, summary)
        {current_week, summary} = current_week(summary)

        summary = %{summary | leagues_seen: map_size(leagues)}
        store_leagues(leagues, season)

        summary =
          Enum.reduce(leagues, summary, fn {id, _name}, acc ->
            crawl_league(id, current_week, acc)
          end)

        {:ok, summary}

      {{:ok, other}, _summary} ->
        {:error, {:unexpected_users_payload, other}}

      {{:error, reason}, _summary} ->
        {:error, {:league_users_failed, reason}}
    end
  end

  # One call per leaguemate. The dedupe is the whole reason this is a crawl:
  # 257 memberships collapse to 176 leagues.
  defp enumerate_leagues(user_ids, season, summary) do
    Enum.reduce(user_ids, {%{}, summary}, fn user_id, {acc, summary} ->
      case request("/user/#{user_id}/leagues/nfl/#{season}", summary) do
        {{:ok, leagues}, summary} when is_list(leagues) ->
          merged =
            Enum.reduce(leagues, acc, fn league, inner ->
              case to_int(league["league_id"]) do
                nil -> inner
                id -> Map.put_new(inner, id, league["name"])
              end
            end)

          {merged, summary}

        {{:error, reason}, summary} ->
          {acc, add_error(summary, {:user_leagues_failed, user_id, reason})}
      end
    end)
  end

  defp store_leagues(leagues, season) do
    leagues
    |> Enum.map(fn {id, name} -> %{id: id, name: name, season: season} end)
    |> Intel.upsert_observed_leagues()
  end

  defp crawl_league(league_id, current_week, summary) do
    league = Repo.get(ObservedLeague, league_id)

    {roster_map, summary} = ensure_roster_map(league, summary)

    weeks = weeks_to_fetch(league && league.transactions_fetched_through, current_week)

    summary =
      Enum.reduce(weeks, summary, fn week, acc ->
        fetch_week(league_id, week, roster_map, acc)
      end)

    # Everything before the current week is settled and never needs fetching
    # again. The current week stays live — in the offseason that is week 1,
    # forever.
    Intel.upsert_observed_leagues([
      %{id: league_id, transactions_fetched_through: max(current_week - 1, 0)}
    ])

    %{summary | leagues_fetched: summary.leagues_fetched + 1}
  end

  # Rosters are fetched once per league and kept: which user owns roster N
  # does not change within a season, and refetching 176 of them nightly to
  # learn nothing would be most of the crawl's budget.
  defp ensure_roster_map(%ObservedLeague{roster_to_user: map}, summary)
       when is_map(map) and map_size(map) > 0,
       do: {map, summary}

  defp ensure_roster_map(league, summary) do
    league_id = league && league.id

    case request("/league/#{league_id}/rosters", summary) do
      {{:ok, rosters}, summary} when is_list(rosters) ->
        map =
          Enum.reduce(rosters, %{}, fn roster, acc ->
            case {roster["roster_id"], to_int(roster["owner_id"])} do
              {nil, _} -> acc
              {_, nil} -> acc
              {roster_id, owner_id} -> Map.put(acc, to_string(roster_id), owner_id)
            end
          end)

        Intel.upsert_observed_leagues([
          %{
            id: league_id,
            roster_to_user: map,
            rosters_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ])

        {map, %{summary | rosters_fetched: summary.rosters_fetched + 1}}

      {{:error, reason}, summary} ->
        # Partial attribution beats none: without the map, `participants/2`
        # still records the creator.
        {%{}, add_error(summary, {:rosters_failed, league_id, reason})}
    end
  end

  defp fetch_week(league_id, week, roster_map, summary) do
    case request("/league/#{league_id}/transactions/#{week}", summary) do
      {{:ok, raw}, summary} when is_list(raw) ->
        rows = Enum.map(raw, &row(&1, league_id, week, roster_map)) |> Enum.reject(&is_nil/1)
        unless rows == [], do: Intel.upsert_observed_transactions(rows)

        %{
          summary
          | weeks_fetched: summary.weeks_fetched + 1,
            transactions_stored: summary.transactions_stored + length(rows)
        }

      {{:ok, _}, summary} ->
        %{summary | weeks_fetched: summary.weeks_fetched + 1}

      {{:error, reason}, summary} ->
        add_error(summary, {:transactions_failed, league_id, week, reason})
    end
  end

  defp row(raw, league_id, week, roster_map) do
    case to_int(raw["transaction_id"]) do
      nil ->
        nil

      id ->
        %{
          id: id,
          league_id: league_id,
          week: week,
          type: raw["type"],
          status: raw["status"],
          created: to_datetime(raw["created"]),
          creator: to_int(raw["creator"]),
          participant_ids: Intel.participants(raw, roster_map),
          adds: raw["adds"] || %{},
          drops: raw["drops"] || %{},
          draft_picks: raw["draft_picks"] || [],
          waiver_bid: get_in(raw, ["settings", "waiver_bid"])
        }
    end
  end

  @doc """
  Which weeks still need fetching, given the highest settled week and the
  current one.

  The current week is **always** included: it is live, and in the offseason
  it is week 1 and stays live indefinitely, because Sleeper files every
  offseason move there.
  """
  @spec weeks_to_fetch(integer | nil, integer) :: [integer]
  def weeks_to_fetch(fetched_through, current_week) do
    current = max(current_week, 1)
    from = max((fetched_through || 0) + 1, 1)

    if from > current, do: [current], else: Enum.to_list(from..current)
  end

  # Sleeper labels the offseason as week 1, which is exactly what this needs:
  # one week to fetch. A failed state call falls back to 1 rather than
  # aborting — the offseason answer is also the safe answer, since it fetches
  # the least.
  defp current_week(summary) do
    case request("/state/nfl", summary) do
      {{:ok, %{"week" => week}}, summary} when is_integer(week) and week > 0 ->
        {week, summary}

      {_, summary} ->
        {1, summary}
    end
  end

  defp request(url, summary) do
    result = Sleeper.get(url)
    {result, %{summary | api_calls: summary.api_calls + 1}}
  end

  defp add_error(summary, error), do: %{summary | errors: [error | summary.errors]}

  defp to_datetime(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp to_datetime(_), do: nil

  defp to_int(nil), do: nil
  defp to_int(i) when is_integer(i), do: i

  # Sleeper sends `""` for an unattributed actor — 3 of 3,286 corpus picks do
  # this, and it took down a whole production crawl once via
  # `String.to_integer/1`. Anything unparseable means "nobody we can
  # attribute this to", which is `nil`.
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
