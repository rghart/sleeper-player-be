defmodule SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts do
  @moduledoc """
  Harvests a league's leaguemates' draft history, per
  `docs/leaguemate-intel.md` §3c/§3f step 3.

  Sequence:

      enumerate leaguemates      GET /v1/league/:id/users
      their drafts (1 call each) GET /v1/user/:id/drafts/nfl/:season
      dedupe by draft_id
      filter to rookie drafts    settings.player_type == 1
      for each draft not already stored as complete:
          GET /v1/draft/:id/picks
          GET /v1/draft/:id/traded_picks

  The refresh rule (the whole caching story, §3c):

    * `status == "complete"` — immutable. Fetched once, never again: a draft
      already stored with status `"complete"` *and* a non-nil
      `picks_fetched_at` is skipped outright.
    * `status == "drafting"` — refetched every crawl (cheap, one draft).
    * `status == "pre_draft"` — no picks to fetch; the draft row is still
      upserted (so it's visible / counted), just never queried for picks.

  Uses `SleeperPlayerApi.Client.Sleeper.get/1` (not `get!/1`) throughout —
  one draft returning a bad response must not abort the rest of the crawl.
  A failed `/picks` or `/traded_picks` call is recorded in the returned
  summary's `:errors` and leaves that draft's `picks_fetched_at` untouched,
  so the next crawl retries it rather than silently treating it as done.
  `get/1` already routes through `SleeperPlayerApi.RateLimiter`, so a 429
  here becomes a throttled wait on the *next* call rather than a hot retry
  loop on this one.

  No Quantum wiring, no controllers — this task is meant to be invoked
  directly (`CrawlLeaguemateDrafts.crawl(league_id, season)`) until later
  plan steps wire it up.
  """

  require Logger

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.ObservedDraft

  # Sleeper's own flag for "this draft is a rookie draft" on the `settings`
  # object of a draft — confirmed against the harvested corpus in
  # `test/support/corpus/rookie_drafts.json` (every entry has
  # `settings.player_type == 1`, nothing else appears there).
  @rookie_player_type 1

  defmodule Summary do
    @moduledoc """
    What a `crawl/2` run did, so a caller (or a log line) can tell a
    complete crawl from a partial one, and so the "second run makes almost
    no calls" checkpoint (§3f step 3) is actually observable.
    """
    defstruct api_calls: 0,
              leaguemates: 0,
              drafts_seen: 0,
              rookie_drafts_seen: 0,
              drafts_fetched: 0,
              drafts_skipped: 0,
              picks_stored: 0,
              traded_picks_stored: 0,
              errors: []
  end

  @doc """
  Crawls one league's leaguemates' rookie draft history for `season` and
  stores it via `SleeperPlayerApi.Intel`.

  Returns `{:ok, %Summary{}}` once the crawl has run to completion (a
  per-draft failure doesn't prevent this — it's recorded in
  `summary.errors` instead), or `{:error, reason}` if the leaguemate
  enumeration call itself fails, since nothing else can proceed without it.
  """
  @spec crawl(integer | String.t(), String.t()) :: {:ok, Summary.t()} | {:error, term}
  def crawl(league_id, season) do
    summary = %Summary{}

    case request("/league/#{league_id}/users", summary) do
      {{:ok, users}, summary} ->
        store_users(users)
        summary = %{summary | leaguemates: length(users)}

        user_ids = Enum.map(users, &to_int(&1["user_id"]))
        {drafts_by_id, summary} = fetch_all_user_drafts(user_ids, season, summary)

        all_drafts = Map.values(drafts_by_id)
        rookie_drafts = Enum.filter(all_drafts, &rookie_draft?/1)

        summary = %{
          summary
          | drafts_seen: map_size(drafts_by_id),
            rookie_drafts_seen: length(rookie_drafts)
        }

        existing = existing_draft_state(Enum.map(rookie_drafts, &draft_id/1))

        # `observed_picks`/`observed_traded_picks` have an FK on
        # `observed_drafts`, so the draft rows have to exist before any
        # picks can be stored for them. Write a placeholder row for every
        # rookie draft up front (one batch), then let `crawl_drafts/3`
        # fetch picks per draft and finalize each row's real status /
        # `picks_fetched_at` in a second batch once the outcome is known.
        unless rookie_drafts == [] do
          rookie_drafts
          |> Enum.map(
            &draft_row(&1, picks_fetched_at: prior_fetched_at(Map.get(existing, draft_id(&1))))
          )
          |> Intel.upsert_observed_drafts()
        end

        {draft_rows, summary} = crawl_drafts(rookie_drafts, existing, summary)

        unless draft_rows == [] do
          Intel.upsert_observed_drafts(draft_rows)
        end

        Logger.info(
          "CrawlLeaguemateDrafts: league #{league_id} season #{season} — " <>
            "#{summary.api_calls} API calls, #{summary.rookie_drafts_seen} rookie drafts seen, " <>
            "#{summary.drafts_fetched} fetched, #{summary.drafts_skipped} skipped (immutable/pre_draft), " <>
            "#{summary.picks_stored} picks stored, #{length(summary.errors)} errors"
        )

        {:ok, summary}

      {{:error, reason}, summary} ->
        Logger.error(
          "CrawlLeaguemateDrafts: could not enumerate league #{league_id} users: #{inspect(reason)}"
        )

        {:error, {:league_users_failed, reason, summary}}
    end
  end

  @doc """
  Refreshes ONE draft's picks/traded_picks on demand, regardless of its
  currently stored status — the `/availability` endpoint's use case (plan
  §3f step 4 scope note: fetching a live in-progress draft "may need
  fetching on demand... reuse [the crawler's refresh rule], don't write a
  second fetch path").

  Fetches `GET /draft/:id` for the draft's current settings/status, then
  hands off to the same private `fetch_draft_picks/3` that `crawl/2` uses —
  so there's exactly one place in the codebase that knows how to fetch and
  store a draft's picks, not two. Unlike `crawl/2`'s per-draft branch, this
  always fetches (a caller reaching for a single-draft refresh already
  wants fresh data right now); the "complete drafts are immutable, skip
  them" short-circuit belongs to the many-drafts league crawl, not this
  path — callers that only want to refresh actually-live drafts should
  check `status` themselves before calling this (see
  `SleeperPlayerApi.Intel.availability/2`).

  Returns `{:ok, %Summary{}}` (same shape as `crawl/2`, `api_calls` counts
  the calls this made) or `{:error, reason}` if even `/draft/:id` fails.
  """
  @spec refresh_draft(integer | String.t()) :: {:ok, Summary.t()} | {:error, term}
  def refresh_draft(draft_id) do
    summary = %Summary{}

    case request("/draft/#{draft_id}", summary) do
      {{:ok, draft}, summary} ->
        id = draft_id(draft)
        existing = existing_draft_state([id])
        prior = Map.get(existing, id)

        # `observed_picks` has an FK on `observed_drafts` — same ordering
        # constraint `crawl/2` handles by pre-inserting a placeholder row
        # before fetching any picks (see its own comment on this).
        Intel.upsert_observed_drafts([draft_row(draft, picks_fetched_at: prior_fetched_at(prior))])

        {row, summary} = fetch_draft_picks(draft, prior, summary)
        Intel.upsert_observed_drafts([row])

        {:ok, summary}

      {{:error, reason}, summary} ->
        Logger.warning(
          "CrawlLeaguemateDrafts: refresh_draft(#{draft_id}) could not fetch /draft/#{draft_id}: #{inspect(reason)}"
        )

        {:error, {:draft_fetch_failed, reason, summary}}
    end
  end

  # ---------------------------------------------------------------------
  # Leaguemates + their drafts
  # ---------------------------------------------------------------------

  defp store_users(users) do
    now = utc_now()

    users
    |> Enum.map(fn u ->
      %{
        id: to_int(u["user_id"]),
        username: u["username"] || u["display_name"],
        display_name: u["display_name"],
        avatar: u["avatar"],
        last_crawled_at: now
      }
    end)
    |> Intel.upsert_sleeper_users()
  end

  defp fetch_all_user_drafts(user_ids, season, summary) do
    Enum.reduce(user_ids, {%{}, summary}, fn user_id, {acc, summary} ->
      {result, summary} = request("/user/#{user_id}/drafts/nfl/#{season}", summary)

      case result do
        {:ok, drafts} ->
          merged = Enum.reduce(drafts, acc, fn d, acc2 -> Map.put_new(acc2, d["draft_id"], d) end)
          {merged, summary}

        {:error, reason} ->
          Logger.warning(
            "CrawlLeaguemateDrafts: drafts fetch failed for user #{user_id}: #{inspect(reason)}"
          )

          {acc, add_error(summary, {:user_drafts, user_id, reason})}
      end
    end)
  end

  defp rookie_draft?(draft), do: get_in(draft, ["settings", "player_type"]) == @rookie_player_type

  # ---------------------------------------------------------------------
  # Per-draft crawl + the refresh rule
  # ---------------------------------------------------------------------

  defp crawl_drafts(rookie_drafts, existing, summary) do
    Enum.reduce(rookie_drafts, {[], summary}, fn draft, {rows, summary} ->
      id = draft_id(draft)
      status = draft["status"]
      prior = Map.get(existing, id)

      cond do
        status == "pre_draft" ->
          # No picks to fetch; keep the row (§3c).
          row = draft_row(draft, picks_fetched_at: prior_fetched_at(prior))
          {[row | rows], %{summary | drafts_skipped: summary.drafts_skipped + 1}}

        status == "complete" and immutable_and_fetched?(prior) ->
          # Already stored complete with picks on file — never refetch.
          row = draft_row(draft, picks_fetched_at: prior_fetched_at(prior))
          {[row | rows], %{summary | drafts_skipped: summary.drafts_skipped + 1}}

        true ->
          # "drafting" (always refetched) or "complete" for the first time.
          {row, summary} = fetch_draft_picks(draft, prior, summary)
          {[row | rows], %{summary | drafts_fetched: summary.drafts_fetched + 1}}
      end
    end)
  end

  defp immutable_and_fetched?(%{status: "complete", picks_fetched_at: fetched_at})
       when not is_nil(fetched_at),
       do: true

  defp immutable_and_fetched?(_prior), do: false

  defp prior_fetched_at(nil), do: nil
  defp prior_fetched_at(%{picks_fetched_at: fetched_at}), do: fetched_at

  defp fetch_draft_picks(draft, prior, summary) do
    id = draft_id(draft)

    {picks_result, summary} = request("/draft/#{id}/picks", summary)
    {traded_result, summary} = fetch_traded_picks(draft, id, summary)

    case {picks_result, traded_result} do
      {{:ok, picks}, {:ok, traded_picks}} ->
        {n_picks, _} = Intel.upsert_observed_picks(id, shape_picks(picks))
        {n_traded, _} = Intel.upsert_observed_traded_picks(id, shape_traded_picks(traded_picks))

        summary = %{
          summary
          | picks_stored: summary.picks_stored + n_picks,
            traded_picks_stored: summary.traded_picks_stored + n_traded
        }

        {draft_row(draft, picks_fetched_at: utc_now()), summary}

      {{:error, reason}, _} ->
        Logger.warning(
          "CrawlLeaguemateDrafts: picks fetch failed for draft #{id}: #{inspect(reason)}"
        )

        row = draft_row(draft, picks_fetched_at: prior_fetched_at(prior))
        {row, add_error(summary, {:picks, id, reason})}

      {{:ok, picks}, {:error, reason}} ->
        # Picks came back fine; store them. Traded-pick resolution failed,
        # so leave `picks_fetched_at` as it was (nil, or the prior value) —
        # this draft is not "done" and the next crawl will retry both.
        {n_picks, _} = Intel.upsert_observed_picks(id, shape_picks(picks))
        summary = %{summary | picks_stored: summary.picks_stored + n_picks}

        Logger.warning(
          "CrawlLeaguemateDrafts: traded_picks fetch failed for draft #{id}: #{inspect(reason)}"
        )

        row = draft_row(draft, picks_fetched_at: prior_fetched_at(prior))
        {row, add_error(summary, {:traded_picks, id, reason})}
    end
  end

  # Traded picks resolve ownership of picks that HAVEN'T BEEN MADE YET — "who
  # actually picks at 35 given the trades" (§3d, §4f). In a *completed* draft
  # that question is already answered: every pick carries `picked_by`, and
  # whoever made a pick owned it, by definition. `Intel.drafts_corpus/1` builds
  # manager attribution purely from `picked_by`; nothing reads
  # `observed_traded_picks` for a completed draft.
  #
  # So we skip the call there. This is a deliberate deviation from §3c, which
  # lists both calls unconditionally per draft. Fetching both for every draft
  # would make a District 13 cold crawl 1 + 13 + 70*2 = 154 calls, which both
  # doubles the load on someone else's API for data we never read and blows
  # §3f step 3's own "≤100 calls" checkpoint. Skipping them gives 1 + 13 + 70 =
  # 84, consistent with the 83 measured in §1.
  #
  # In-progress drafts still fetch them, which is the case that needs them.
  defp fetch_traded_picks(%{"status" => "complete"}, _id, summary), do: {{:ok, []}, summary}

  defp fetch_traded_picks(_draft, id, summary),
    do: request("/draft/#{id}/traded_picks", summary)

  defp existing_draft_state(draft_ids) do
    from(d in ObservedDraft,
      where: d.id in ^draft_ids,
      select: {d.id, %{status: d.status, picks_fetched_at: d.picks_fetched_at}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------
  # Shaping raw Sleeper JSON into `Intel` upsert input
  # ---------------------------------------------------------------------

  defp draft_id(draft), do: to_int(draft["draft_id"])

  defp draft_row(draft, picks_fetched_at: picks_fetched_at) do
    %{
      id: draft_id(draft),
      league_id: to_int(draft["league_id"]),
      league_name: get_in(draft, ["metadata", "name"]),
      season: draft["season"],
      status: draft["status"],
      draft_type: draft["type"],
      player_type: get_in(draft, ["settings", "player_type"]),
      teams: get_in(draft, ["settings", "teams"]),
      rounds: get_in(draft, ["settings", "rounds"]),
      start_time: draft["start_time"],
      slot_to_roster_id: draft["slot_to_roster_id"],
      picks_fetched_at: picks_fetched_at
    }
  end

  defp shape_picks(picks) do
    Enum.map(picks, fn p ->
      %{
        pick_no: p["pick_no"],
        round: p["round"],
        draft_slot: p["draft_slot"],
        roster_id: p["roster_id"],
        player_id: p["player_id"],
        picked_by: to_int(p["picked_by"])
      }
    end)
  end

  defp shape_traded_picks(traded_picks) do
    Enum.map(traded_picks, fn t ->
      %{
        season: t["season"],
        round: t["round"],
        roster_id: t["roster_id"],
        previous_owner_id: to_int(t["previous_owner_id"]),
        owner_id: to_int(t["owner_id"])
      }
    end)
  end

  # ---------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------

  defp request(url, summary) do
    result = Sleeper.get(url)
    {result, %{summary | api_calls: summary.api_calls + 1}}
  end

  defp add_error(summary, error), do: %{summary | errors: [error | summary.errors]}

  defp to_int(nil), do: nil
  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
