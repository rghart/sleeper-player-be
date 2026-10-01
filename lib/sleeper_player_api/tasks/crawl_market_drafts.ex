defmodule SleeperPlayerApi.Tasks.CrawlMarketDrafts do
  @moduledoc """
  Grows the market draft corpus for ADP from real drafts
  (docs/dynasty-engine.md, M3), within a fixed budget of Sleeper calls a
  night.

  **Where it looks.** The frontier (`market_users`) starts from the
  leaguemate corpus's users and snowballs: every league a qualifying draft
  belongs to adds its users, one step further out. The leaguemate corpus
  alone is one league's neighbourhood, which is useful for intel but is not
  the market; each step out dilutes that bias.

  **What a run does**, user by user, until the budget is spent:

      GET /user/:id/drafts/nfl/:season         1 call per user
        each draft that qualifies (Market.Format.classify/2) and is new:
          GET /league/:id                       1 call, first time per league
          GET /league/:id/users                 1 call, first time per league
          GET /draft/:id/picks                  1 call, unless its bucket is full

  **What keeps it bounded.**

    * `calls_per_run` (config, default 1,500): roughly five minutes at the
      shared `RateLimiter`'s 300/min, and well inside Sleeper's 1,000/min.
    * `target_per_bucket` (default 150): a format bucket with that many
      complete drafts in the window stops taking more. ADP's error shrinks
      with the square root of the sample, so past that more drafts barely
      sharpen it.
    * `revisit_days` (default 30): a crawled user is not read again until
      then, so the budget goes to new users first.

  **Memory.** The VM has under a gigabyte. Each draft is fetched, stored and
  dropped before the next; nothing accumulates across a run but counters.
  """

  require Logger

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Market
  alias SleeperPlayerApi.Market.Format
  alias SleeperPlayerApi.Repo

  defp config(key, default) do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defmodule Summary do
    @moduledoc "What a run did: calls spent, drafts stored, and why the rest were skipped."
    defstruct calls: 0,
              budget: 0,
              users_crawled: 0,
              users_added: 0,
              leagues_read: 0,
              drafts_seen: 0,
              drafts_stored: 0,
              drafts_incomplete: 0,
              skipped: %{},
              errors: 0,
              stopped: nil
  end

  @doc """
  The scheduled entry point. Never raises: a failed run logs and returns, so
  the Quantum worker survives it.
  """
  def run do
    crawl()
  rescue
    e ->
      Logger.error("CrawlMarketDrafts: raised: #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  end

  @doc """
  Runs one crawl. Options override config: `:budget`, `:season`,
  `:target_per_bucket`, `:revisit_days`.

  Returns `{:ok, %Summary{}}`.
  """
  def crawl(opts \\ []) do
    budget = Keyword.get(opts, :budget, config(:calls_per_run, 1_500))
    target = Keyword.get(opts, :target_per_bucket, config(:target_per_bucket, 150))
    revisit_days = Keyword.get(opts, :revisit_days, config(:revisit_days, 30))

    summary = %Summary{budget: budget}
    {season, summary} = season(opts, summary)
    seed_frontier()

    state = %{
      budget: budget,
      target: target,
      season: season,
      counts: Market.bucket_counts(Format.window_start()),
      revisit_before: DateTime.add(DateTime.utc_now(), -revisit_days * 86_400, :second)
    }

    summary = crawl_users(state, summary)
    {total, uncrawled} = Market.frontier_size()

    Logger.info(
      "CrawlMarketDrafts: #{summary.calls} calls, #{summary.users_crawled} users, " <>
        "#{summary.drafts_stored} drafts stored (#{summary.drafts_incomplete} incomplete), " <>
        "skipped #{inspect(summary.skipped)}, frontier #{total} (#{uncrawled} uncrawled), " <>
        "stopped: #{summary.stopped}"
    )

    {:ok, summary}
  end

  # Sleeper's own label for the season leagues are in; the calendar year if
  # the state endpoint cannot be read. Costs one call when not given.
  defp season(opts, summary) do
    case Keyword.fetch(opts, :season) do
      {:ok, season} ->
        {to_string(season), summary}

      :error ->
        case call("/state/nfl", summary) do
          {{:ok, %{"league_season" => season}}, summary} -> {to_string(season), summary}
          {_, summary} -> {Integer.to_string(Date.utc_today().year), summary}
        end
    end
  end

  # The leaguemate corpus's users are the seeds. Re-seeding every run is
  # cheap (conflicts are ignored) and picks up leaguemates crawled since.
  defp seed_frontier do
    from(u in SleeperPlayerApi.Intel.SleeperUser, select: u.id)
    |> Repo.all()
    |> Market.add_users(0)
  end

  defp crawl_users(state, summary) do
    cond do
      summary.calls >= state.budget ->
        %{summary | stopped: :budget}

      Enum.all?(state.counts, fn {_bucket, n} -> n >= state.target end) ->
        %{summary | stopped: :all_buckets_full}

      true ->
        case Market.next_users(50, state.revisit_before) do
          [] ->
            %{summary | stopped: :frontier_exhausted}

          users ->
            {state, summary} =
              Enum.reduce_while(users, {state, summary}, fn user, {state, summary} ->
                if summary.calls >= state.budget,
                  do: {:halt, {state, summary}},
                  else: {:cont, crawl_user(user, state, summary)}
              end)

            crawl_users(state, summary)
        end
    end
  end

  defp crawl_user(user, state, summary) do
    {result, summary} = call("/user/#{user.id}/drafts/nfl/#{state.season}", summary)
    Market.mark_user_crawled(user.id)
    summary = %{summary | users_crawled: summary.users_crawled + 1}

    case result do
      {:ok, drafts} when is_list(drafts) ->
        known = Market.known_drafts(Enum.map(drafts, & &1["draft_id"]))

        Enum.reduce(drafts, {state, summary}, fn draft, {state, summary} ->
          summary = %{summary | drafts_seen: summary.drafts_seen + 1}

          cond do
            summary.calls >= state.budget ->
              {state, summary}

            MapSet.member?(known, to_int(draft["draft_id"])) ->
              {state, skip(summary, :already_stored)}

            true ->
              consider(draft, user, state, summary)
          end
        end)

      _ ->
        {state, %{summary | errors: summary.errors + 1}}
    end
  end

  defp consider(draft, user, state, summary) do
    case Format.classify(draft) do
      {:skip, reason} ->
        {state, skip(summary, reason)}

      {:ok, kind} ->
        # The QB format is on the draft; only a bucket that is full for
        # both TE-premium variants can be skipped before reading the league.
        qb_slots = Format.qb_slots(draft)

        if full?(state, Format.bucket(kind, qb_slots, 0)) and
             full?(state, Format.bucket(kind, qb_slots, 1)) do
          {state, skip(summary, :bucket_full)}
        else
          with_league(draft, kind, qb_slots, user, state, summary)
        end
    end
  end

  defp with_league(draft, kind, qb_slots, user, state, summary) do
    {league, summary} = league(draft["league_id"], user, summary)

    cond do
      league == nil and spent?(summary) ->
        # The budget ran out before the league could be read; the draft is
        # not stored, so the next run comes back to it.
        {state, summary}

      league == nil ->
        {state, %{summary | errors: summary.errors + 1}}

      league.league_type != 2 ->
        # Scored as dynasty but not a dynasty league (a keeper league, say).
        {state, skip(summary, :league_not_dynasty)}

      full?(state, Format.bucket(kind, qb_slots, league.te_premium)) ->
        {state, skip(summary, :bucket_full)}

      true ->
        store(draft, kind, qb_slots, league, state, summary)
    end
  end

  defp store(draft, kind, qb_slots, league, state, summary) do
    id = to_int(draft["draft_id"])
    {result, summary} = call("/draft/#{id}/picks", summary)

    case result do
      {:ok, picks} when is_list(picks) ->
        settings = draft["settings"] || %{}

        {:ok, stored} =
          Market.store_draft(
            %{
              id: id,
              league_id: to_int(draft["league_id"]),
              season: draft["season"],
              kind: kind,
              draft_type: draft["type"],
              teams: settings["teams"],
              rounds: settings["rounds"],
              qb_slots: qb_slots,
              te_premium: league.te_premium,
              ppr: league.ppr,
              scoring_type: get_in(draft, ["metadata", "scoring_type"]),
              started_at:
                draft["start_time"]
                |> DateTime.from_unix!(:millisecond)
                |> DateTime.truncate(:second)
            },
            picks
          )

        if stored.complete do
          bucket = Format.bucket(kind, qb_slots, league.te_premium)
          state = update_in(state, [:counts, bucket], &((&1 || 0) + 1))
          {state, %{summary | drafts_stored: summary.drafts_stored + 1}}
        else
          {state,
           %{
             summary
             | drafts_stored: summary.drafts_stored + 1,
               drafts_incomplete: summary.drafts_incomplete + 1
           }}
        end

      _ ->
        errors = if spent?(summary), do: summary.errors, else: summary.errors + 1
        {state, %{summary | errors: errors}}
    end
  end

  # A league's format, read once and kept. The first read also adds its users
  # to the frontier, one step further out than the user who led here.
  defp league(league_id, user, summary) do
    case Market.get_league(league_id) do
      # Stored, but the run that read it ran out of budget before its users:
      # add them now, or this league would never widen the frontier.
      %{users_crawled_at: nil} = league ->
        {league, add_league_users(league_id, user, summary)}

      %{} = league ->
        {league, summary}

      nil ->
        case call("/league/#{league_id}", summary) do
          {{:ok, %{} = raw}, summary} ->
            league = Market.put_league(raw)
            summary = %{summary | leagues_read: summary.leagues_read + 1}
            {league, add_league_users(league_id, user, summary)}

          {_, summary} ->
            {nil, summary}
        end
    end
  end

  defp add_league_users(league_id, user, summary) do
    case call("/league/#{league_id}/users", summary) do
      {{:ok, users}, summary} when is_list(users) ->
        added = Market.add_users(Enum.map(users, & &1["user_id"]), user.depth + 1)
        Market.mark_league_users_crawled(league_id)
        %{summary | users_added: summary.users_added + added}

      {_, summary} ->
        summary
    end
  end

  defp full?(state, bucket), do: Map.get(state.counts, bucket, 0) >= state.target

  defp skip(summary, reason),
    do: %{summary | skipped: Map.update(summary.skipped, reason, 1, &(&1 + 1))}

  # Every Sleeper call goes through here, so the budget bounds all of them:
  # once it is spent, nothing more goes out, whatever step a run is on.
  defp call(_path, %{calls: calls, budget: budget} = summary) when calls >= budget,
    do: {{:error, :budget_spent}, summary}

  defp call(path, summary) do
    {Sleeper.get(path), %{summary | calls: summary.calls + 1}}
  end

  defp spent?(summary), do: summary.calls >= summary.budget

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
