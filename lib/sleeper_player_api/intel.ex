defmodule SleeperPlayerApi.Intel do
  @moduledoc """
  Context for the leaguemate-intel corpus: storing the Sleeper drafts/picks
  harvested by `SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts` (see
  `docs/leaguemate-intel.md` §3f steps 2-3), and shaping what's stored back
  out into the plain-map input `SleeperPlayerApi.Intel.Estimator` expects.

  Two halves, per the plan's §3e "where the math runs":

    * **Upserts** — batched `Repo.insert_all/3` with `on_conflict`, never a
      per-row SELECT+INSERT (that's the exact pattern `GetSleeperPlayerData`
      uses across ~9,400 players, and the plan calls out that the crawler
      must not copy it).
    * **Queries** — `GROUP BY` aggregates (league ADP/spread, per-manager
      ADP/counts) computed in SQL, plus `drafts_corpus/1`, which shapes
      `observed_drafts`/`observed_picks` into exactly the structure
      `test/support/intel_corpus.ex` builds from JSON, so the estimator is
      indifferent to which one fed it.

  `availability/2` (plan §3f step 4) is the one exception to "no HTTP" —
  resolving trade-aware pick ownership needs a live `/league/:id/rosters`
  call (see its doc) and a live `/draft/:id` call for `slot_to_roster_id`
  (see `fetch_slot_to_roster_id/1` — the crawler's own listing call never
  gets that field, so it can't come from the DB alone) and, for an
  in-progress draft, a refresh through
  `SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts.refresh_draft/1`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel.{Estimator, Availability}

  alias SleeperPlayerApi.Intel.{
    SleeperUser,
    ObservedDraft,
    ObservedPick,
    ObservedTradedPick,
    PlayerValue,
    DraftParticipant,
    ObservedLeague,
    ObservedTransaction
  }

  @batch_size 1000

  # ---------------------------------------------------------------------
  # Upserts
  # ---------------------------------------------------------------------

  @doc """
  Upserts a batch of `%{id, username, display_name, avatar, last_crawled_at}`
  maps into `sleeper_users`, keyed on `id` (Sleeper's own user id — never
  `username`, which Sleeper documents as mutable).
  """
  @spec upsert_sleeper_users([map]) :: {non_neg_integer, nil}
  def upsert_sleeper_users(users) do
    insert_all_batched(
      SleeperUser,
      users,
      conflict_target: [:id],
      replace: [:username, :display_name, :avatar, :last_crawled_at]
    )
  end

  @doc """
  Upserts a batch of draft attribute maps into `observed_drafts`, keyed on
  `id` (the Sleeper draft id).
  """
  @spec upsert_observed_drafts([map]) :: {non_neg_integer, nil}
  def upsert_observed_drafts(drafts) do
    insert_all_batched(
      ObservedDraft,
      drafts,
      conflict_target: [:id],
      replace: [
        :league_id,
        :league_name,
        :season,
        :status,
        :draft_type,
        :player_type,
        :teams,
        :rounds,
        :start_time,
        :slot_to_roster_id,
        :picks_fetched_at
      ]
    )
  end

  @doc """
  Upserts every pick of one draft into `observed_picks`. `picks` entries omit
  `draft_id` — it's stamped onto every row here so callers just pass what
  `/draft/:id/picks` returns.

  Keyed on `(draft_id, pick_no)`, so re-crawling an in-progress draft (the
  `status == "drafting"` refresh case from plan §3c) safely overwrites.

  Also upserts `draft_participants` for this draft — every distinct non-nil
  `picked_by` among the picks just stored (plan §3a's rationale for the
  table: "avoids re-deriving participation from `observed_picks` every
  query"). This is deliberately done *here*, as a side effect of storing
  picks, rather than as a separate call `CrawlLeaguemateDrafts` has to
  remember to make: every caller that stores picks (the crawl itself,
  `refresh_draft/1`, and any test that seeds through this function rather
  than a DB-seeding shortcut) gets participants for free and can never drift
  from what `observed_picks` says, which is exactly the bug class flagged in
  the report on this step. `upsert_draft_participants/2` is itself
  conflict-safe, so re-storing the same picks (a `"drafting"` refresh) is a
  no-op here too.
  """
  @spec upsert_observed_picks(integer, [map]) :: {non_neg_integer, nil}
  def upsert_observed_picks(draft_id, picks) do
    stamped = Enum.map(picks, &Map.put(&1, :draft_id, draft_id))

    result =
      insert_all_batched(
        ObservedPick,
        stamped,
        conflict_target: [:draft_id, :pick_no],
        replace: [:round, :draft_slot, :roster_id, :player_id, :picked_by]
      )

    participant_ids =
      stamped
      |> Enum.map(& &1[:picked_by])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    unless participant_ids == [] do
      upsert_draft_participants(draft_id, participant_ids)
    end

    result
  end

  @doc """
  Upserts one draft's traded-pick rows into `observed_traded_picks`.
  `/draft/:id/traded_picks` doesn't return a `draft_id` field (it's implicit
  in the URL), so it's stamped on here same as `upsert_observed_picks/2`.

  Keyed on `(draft_id, season, round, roster_id)` — the natural key for "who
  owns this future pick".
  """
  @spec upsert_observed_traded_picks(integer, [map]) :: {non_neg_integer, nil}
  def upsert_observed_traded_picks(draft_id, traded_picks) do
    traded_picks
    |> Enum.map(&Map.put(&1, :draft_id, draft_id))
    |> then(
      &insert_all_batched(
        ObservedTradedPick,
        &1,
        conflict_target: [:draft_id, :season, :round, :roster_id],
        replace: [:previous_owner_id, :owner_id]
      )
    )
  end

  @doc """
  Upserts the `(draft_id, user_id)` participation join rows for one draft.
  Idempotent — re-running with the same `user_ids` is a no-op on conflict.
  """
  @spec upsert_draft_participants(integer, [integer]) :: {non_neg_integer, nil}
  def upsert_draft_participants(draft_id, user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.map(&%{draft_id: draft_id, user_id: &1})
    |> then(
      &insert_all_batched(
        DraftParticipant,
        &1,
        conflict_target: [:draft_id, :user_id],
        on_conflict: :nothing
      )
    )
  end

  @doc """
  Backfills `draft_participants` from every `draft_id`/non-nil-`picked_by`
  pair already sitting in `observed_picks` — the one-time catch-up for
  production, where `observed_picks` has ~3,400 rows and
  `draft_participants` has zero, because nothing called
  `upsert_draft_participants/2` before `upsert_observed_picks/2` started
  doing it as a side effect (see that function's doc, and the report on this
  step). Called from the `20260806140100_backfill_draft_participants.exs`
  migration's `up/0`.

  Idempotent — safe to run twice. Every row it writes goes through
  `upsert_draft_participants/2`, which is itself `on_conflict: :nothing` on
  `(draft_id, user_id)`, so a second run touches nothing and inserts no
  duplicates.
  """
  @spec backfill_draft_participants() :: {non_neg_integer, nil}
  def backfill_draft_participants do
    from(p in ObservedPick,
      where: not is_nil(p.picked_by),
      distinct: true,
      select: {p.draft_id, p.picked_by}
    )
    |> Repo.all()
    |> Enum.group_by(fn {draft_id, _user_id} -> draft_id end, fn {_draft_id, user_id} ->
      user_id
    end)
    |> Enum.reduce({0, nil}, fn {draft_id, user_ids}, {count, _} ->
      {n, _} = upsert_draft_participants(draft_id, user_ids)
      {count + n, nil}
    end)
  end

  @doc """
  Upserts a batch of `%{player_id, source, value, ...}` maps into
  `player_values`, keyed on `(player_id, source)` — one row per provider per
  player, refreshed in place (see plan §2's swappable-`source` design).
  """
  @spec upsert_player_values([map]) :: {non_neg_integer, nil}
  def upsert_player_values(values) do
    insert_all_batched(
      PlayerValue,
      values,
      conflict_target: [:player_id, :source],
      replace: [
        :value,
        :overall_rank,
        :position_rank,
        :roster_percent,
        :trade_frequency,
        :as_of,
        :draft_year
      ]
    )
  end

  # ---------------------------------------------------------------------
  # Transactions (plan §6 step 6)
  # ---------------------------------------------------------------------

  @doc """
  Upserts leagues by Sleeper league id.

  `roster_to_user` is stored as given (string roster-id keys, since it
  round-trips as jsonb) and is only replaced when the caller actually
  supplies one — a crawl that fetched transactions but not rosters must not
  blank out a map an earlier pass already stored.
  """
  @spec upsert_observed_leagues([map]) :: {non_neg_integer, nil}
  def upsert_observed_leagues(leagues) do
    insert_all_batched(
      ObservedLeague,
      leagues,
      conflict_target: [:id],
      on_conflict:
        from(l in ObservedLeague,
          update: [
            set: [
              name: fragment("COALESCE(EXCLUDED.name, ?)", l.name),
              season: fragment("COALESCE(EXCLUDED.season, ?)", l.season),
              roster_to_user: fragment("COALESCE(EXCLUDED.roster_to_user, ?)", l.roster_to_user),
              rosters_fetched_at:
                fragment("COALESCE(EXCLUDED.rosters_fetched_at, ?)", l.rosters_fetched_at),
              transactions_fetched_through:
                fragment(
                  "GREATEST(COALESCE(EXCLUDED.transactions_fetched_through, 0), COALESCE(?, 0))",
                  l.transactions_fetched_through
                )
            ]
          ]
        )
    )
  end

  @doc """
  Upserts transactions by Sleeper transaction id.

  Keyed on the transaction's own id rather than a synthetic one because a
  *live* week is refetched repeatedly — in the offseason every transaction
  lands in week 1 and week 1 never closes, so the same rows come back nightly
  for months. Anything else would duplicate.
  """
  @spec upsert_observed_transactions([map]) :: {non_neg_integer, nil}
  def upsert_observed_transactions(transactions) do
    insert_all_batched(
      ObservedTransaction,
      transactions,
      conflict_target: [:id],
      replace: [
        :league_id,
        :week,
        :type,
        :status,
        :created,
        :creator,
        :participant_ids,
        :adds,
        :drops,
        :draft_picks,
        :waiver_bid
      ]
    )
  end

  @doc """
  Resolves the roster ids on a raw transaction payload to the user ids behind
  them, using a league's `roster_to_user` map.

  This is the whole reason `observed_leagues` exists. `creator` is a *user*
  id; `roster_ids` and `consenter_ids` are *roster* ids. Attributing a trade
  only to its creator drops the manager who accepted it, and trades are both
  the rarest transaction type and the most interesting — so the undercount
  would be invisible and would lose exactly the wrong half.

  The creator is always included, even when their roster is missing from the
  map (a league whose rosters have not been fetched yet still yields partial
  attribution rather than none).
  """
  @spec participants(map, map) :: [integer]
  def participants(raw, roster_to_user) do
    from_rosters =
      raw
      |> Map.get("roster_ids", [])
      |> Enum.map(&Map.get(roster_to_user, to_string(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_int/1)

    [to_int(raw["creator"]) | from_rosters]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every stored transaction a user was involved in, newest first.

  Reads `participant_ids`, not `creator` — see `participants/2`.

  `:limit` caps the rows; `:season` scopes to one season's leagues; `:types`
  narrows to particular transaction types. `status: "failed"` rows are
  included by default and it is deliberate: a failed waiver claim is a
  revealed preference nobody else in that league can see. Filter it where it
  is displayed, with a label, not here.
  """
  @spec transactions_for_user(integer | String.t(), keyword) :: [ObservedTransaction.t()]
  def transactions_for_user(user_id, opts \\ []) do
    user_id = to_int(user_id)
    limit = Keyword.get(opts, :limit, 50)

    ObservedTransaction
    |> where([t], ^user_id in t.participant_ids)
    |> then(fn q ->
      case Keyword.get(opts, :types) do
        nil -> q
        types -> where(q, [t], t.type in ^types)
      end
    end)
    |> then(fn q ->
      case Keyword.get(opts, :season) do
        nil ->
          q

        season ->
          join(q, :inner, [t], l in ObservedLeague,
            on: l.id == t.league_id and l.season == ^season
          )
      end
    end)
    |> order_by([t], desc: t.created, desc: t.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How much of a user's activity the store can actually see: how many leagues
  hold a transaction of theirs, and how many leagues are known at all.

  This is what the endpoint reports as `coverage`. A fan-out that saw 38 of 42
  leagues and reports "5 trades" is a figure without its sample size, which is
  the error this feature keeps re-learning.
  """
  @spec transaction_coverage(integer | String.t(), keyword) :: map
  def transaction_coverage(user_id, opts \\ []) do
    user_id = to_int(user_id)
    season = Keyword.get(opts, :season)

    leagues_seen =
      ObservedTransaction
      |> where([t], ^user_id in t.participant_ids)
      |> select([t], count(fragment("DISTINCT ?", t.league_id)))
      |> Repo.one()

    known =
      ObservedLeague
      |> then(fn q -> if season, do: where(q, [l], l.season == ^season), else: q end)
      |> select([l], count(l.id))
      |> Repo.one()

    last =
      ObservedLeague
      |> select([l], max(l.rosters_fetched_at))
      |> Repo.one()

    %{leagues_seen: leagues_seen || 0, leagues_known: known || 0, last_crawled_at: last}
  end

  defp insert_all_batched(schema, entries, opts) do
    {conflict_target, opts} = Keyword.pop!(opts, :conflict_target)

    on_conflict =
      case Keyword.pop(opts, :replace) do
        {nil, opts} -> Keyword.fetch!(opts, :on_conflict)
        {fields, _opts} -> {:replace, fields}
      end

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries
    |> Enum.map(&stamp_timestamps(&1, now))
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce({0, nil}, fn chunk, {count, _} ->
      {n, _} =
        Repo.insert_all(schema, chunk, on_conflict: on_conflict, conflict_target: conflict_target)

      {count + n, nil}
    end)
  end

  defp stamp_timestamps(entry, now) do
    entry
    |> Map.put_new(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  # ---------------------------------------------------------------------
  # Corpus shaping — the estimator-input adapter
  # ---------------------------------------------------------------------

  @doc """
  Every stored draft, shaped into exactly the input
  `SleeperPlayerApi.Intel.Estimator` expects:

      %{l_d: float, picks: [%{norm: float, player_id: String.t(), manager: String.t() | nil}]}

  `user_id_to_manager` is `%{integer => String.t()}` (Sleeper user id ->
  leaguemate display name) — the DB-backed analog of
  `SleeperPlayerApi.IntelCorpus.user_id_to_manager/0`. A pick whose
  `picked_by` isn't in the map gets `manager: nil`, same as the JSON path.

  Drafts with no stored picks are skipped (`Enum.max/1` on an empty pick
  list is undefined, same trap the JSON loader would hit — the crawler is
  expected to only mark a draft's picks fetched once it actually has some).

  Picks within a draft are returned in ascending `pick_no` order for
  determinism; `IntelCorpus.drafts/0` preserves JSON array order, which is
  already pick order, so the two are directly comparable once sorted the
  same way.

  Only `status == "complete"` drafts are included — the estimator's own
  vocabulary (`docs/leaguemate-intel-estimator.md` §0) defines the corpus
  as "the *completed* rookie drafts observed", and an in-progress draft's
  `l_d` moves every time it's refetched, which would make the corpus (and
  therefore every survival number computed from it) shift under a caller's
  feet mid-request. This was unfiltered before `/availability` needed it —
  nothing consumed it in a way that could tell the difference yet — so this
  is a real behaviour change, not a no-op refactor; see the PR/report for
  the plan gap this closes.

  `opts[:exclude_draft_id]` additionally drops one specific draft from the
  corpus — for `/availability`, that's the very draft being analyzed. A
  live in-progress draft has `status == "drafting"` so §-filter above
  already excludes it, but the option exists for the moment that draft
  finishes: without it, a completed live draft would count itself as
  evidence for its own trade-resolved board, which is circular.
  """
  @spec drafts_corpus(%{integer => String.t()}, keyword) :: [map]
  def drafts_corpus(user_id_to_manager \\ %{}, opts \\ []) do
    exclude_draft_id = Keyword.get(opts, :exclude_draft_id)

    teams_by_draft =
      from(d in ObservedDraft, where: d.status == "complete", select: {d.id, d.teams})
      |> Repo.all()
      |> Map.new()

    picks_by_draft =
      from(p in ObservedPick,
        where: p.draft_id in ^Map.keys(teams_by_draft),
        order_by: [asc: p.draft_id, asc: p.pick_no]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.draft_id)

    for {draft_id, picks} <- picks_by_draft, picks != [], draft_id != exclude_draft_id do
      teams = Map.fetch!(teams_by_draft, draft_id)

      shaped_picks =
        for pick <- picks do
          %{
            norm: normalize(pick.pick_no, teams),
            player_id: pick.player_id,
            manager: Map.get(user_id_to_manager, pick.picked_by)
          }
        end

      max_pick_no = picks |> Enum.map(& &1.pick_no) |> Enum.max()

      %{l_d: normalize(max_pick_no, teams), picks: shaped_picks}
    end
  end

  defp normalize(pick_no, teams), do: (pick_no - 1) / teams * 12 + 1

  # ---------------------------------------------------------------------
  # GROUP BY aggregates (plan §3e / §4a / §4e)
  # ---------------------------------------------------------------------

  @doc """
  League-wide ADP summary for one player: `n`, `adp` (mean), `sd`
  (population — `STDDEV_POP`, matching `Estimator.adp_summary/1`'s choice,
  see its moduledoc), `min`, `max` — over every normalized pick at which he
  was taken across every stored draft. `nil` if the player was never taken
  in the corpus.

  This is a `GROUP BY` aggregate computed in SQL, per plan §3e — it's the
  same number `Estimator.adp_summary/1` produces from `player_events/2`, just
  computed without pulling every row into the app first.
  """
  @spec league_adp_summary(String.t()) ::
          %{n: non_neg_integer, adp: float, sd: float, min: float, max: float} | nil
  def league_adp_summary(player_id) do
    # `fragment/1` is a query macro, expanded at compile time — it can't be
    # factored into a runtime helper and interpolated with `^` here, because
    # Ecto only allows a *whole* dynamic expression to be interpolated at
    # the top level of `select` (not nested inside `avg(...)`/`fragment(...)`
    # calls). So the normalization formula is written out at each use site
    # instead — same SQL text as `Estimator.normalize_pick/2`, just run by
    # Postgres over every stored row instead of pulled into the app first.
    result =
      from(p in ObservedPick,
        join: d in ObservedDraft,
        on: d.id == p.draft_id,
        where: p.player_id == ^player_id,
        select: %{
          n: count(p.pick_no),
          adp: avg(fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams)),
          sd: fragment("stddev_pop(((? - 1)::float / ? * 12) + 1)", p.pick_no, d.teams),
          min: min(fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams)),
          max: max(fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams))
        }
      )
      |> Repo.one()

    case result do
      %{n: 0} ->
        nil

      %{n: nil} ->
        nil

      %{n: n, adp: adp, sd: sd, min: min, max: max} ->
        %{n: n, adp: adp * 1.0, sd: sd_or_zero(sd), min: min * 1.0, max: max * 1.0}
    end
  end

  defp sd_or_zero(nil), do: 0.0
  defp sd_or_zero(sd), do: sd * 1.0

  @doc """
  Per-manager ADP summary for one player: one row per `picked_by` that has
  ever taken him, each with the same `n`/`adp`/`sd`/`min`/`max` shape as
  `league_adp_summary/1` plus the literal picks used
  (`round.draft_slot @ pick_no`), per plan §4e ("store every individual
  pick... so the UI can show receipts").
  """
  @spec manager_adp_summary(String.t()) :: [
          %{
            user_id: integer,
            n: non_neg_integer,
            adp: float,
            sd: float,
            min: float,
            max: float,
            picks: [%{round: integer | nil, draft_slot: integer | nil, pick_no: integer}]
          }
        ]
  def manager_adp_summary(player_id) do
    rows =
      from(p in ObservedPick,
        join: d in ObservedDraft,
        on: d.id == p.draft_id,
        where: p.player_id == ^player_id and not is_nil(p.picked_by),
        order_by: [asc: p.picked_by],
        select: %{
          user_id: p.picked_by,
          norm: fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams),
          round: p.round,
          draft_slot: p.draft_slot,
          pick_no: p.pick_no
        }
      )
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {user_id, entries} ->
      norms = Enum.map(entries, & &1.norm)
      n = length(norms)
      mean = Enum.sum(norms) / n

      variance =
        Enum.reduce(norms, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n

      %{
        user_id: user_id,
        n: n,
        adp: mean,
        sd: :math.sqrt(variance),
        min: Enum.min(norms),
        max: Enum.max(norms),
        picks:
          Enum.map(entries, fn e ->
            %{round: e.round, draft_slot: e.draft_slot, pick_no: e.pick_no}
          end)
      }
    end)
    |> Enum.sort_by(& &1.user_id)
  end

  @doc """
  `%{user_id => count of distinct drafts}` — "how many drafts have we
  observed this manager in at all", the `seen_m` input to the estimator's
  manager multiplier (§6).

  Reads `draft_participants` rather than `GROUP BY`-ing `observed_picks`
  directly — the exact point of that table per plan §3a ("avoids re-deriving
  participation from `observed_picks` every query"). `Intel.upsert_observed_picks/2`
  keeps it populated as a side effect of storing picks, so this is
  equivalent to the old direct-from-`observed_picks` query, just without
  re-scanning every pick row on every call. `user_id` here is *any* Sleeper
  user id observed picking, tracked leaguemate or not — same scope the old
  query had (`not is_nil(picked_by)`, no filter on `sleeper_users`
  membership).
  """
  @spec manager_drafts_seen() :: %{integer => non_neg_integer}
  def manager_drafts_seen do
    from(dp in DraftParticipant,
      group_by: dp.user_id,
      select: {dp.user_id, count(dp.draft_id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------
  # `/availability` adapter (plan §3e / §3f step 4)
  # ---------------------------------------------------------------------

  @doc """
  A single stored draft, or `nil` if it's never been crawled at all.
  """
  @spec get_observed_draft(integer | String.t()) :: ObservedDraft.t() | nil
  def get_observed_draft(draft_id), do: Repo.get(ObservedDraft, to_int(draft_id))

  @doc """
  Every stored pick of one draft, ascending by `pick_no` — "what's already
  been made", the input to resolving `currentPick` and excluding drafted
  players from `targets`.
  """
  @spec draft_picks(integer) :: [%{pick_no: integer, player_id: String.t() | nil}]
  def draft_picks(draft_id) do
    from(p in ObservedPick,
      where: p.draft_id == ^draft_id,
      order_by: [asc: p.pick_no],
      select: %{pick_no: p.pick_no, player_id: p.player_id}
    )
    |> Repo.all()
  end

  @doc """
  One draft's traded-pick ledger as `%{{round, original_roster_id} =>
  new_roster_id}` — exactly the shape
  `SleeperPlayerApi.Intel.PickOwnership.resolve_roster/5` expects.
  """
  @spec draft_traded_picks(integer) :: %{{integer, integer} => integer}
  def draft_traded_picks(draft_id) do
    from(t in ObservedTradedPick, where: t.draft_id == ^draft_id)
    |> Repo.all()
    |> Map.new(fn t -> {{t.round, t.roster_id}, t.owner_id} end)
  end

  @doc """
  `%{sleeper_user_id => display_name}` for every stored leaguemate — the
  `user_id_to_manager` input `drafts_corpus/2` and
  `SleeperPlayerApi.Intel.Availability` both take.
  """
  @spec manager_names_by_id() :: %{integer => String.t()}
  def manager_names_by_id do
    from(u in SleeperUser, select: {u.id, u.display_name})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Live `roster_id -> owner sleeper_user_id` for a league, via `GET
  /league/:id/rosters`. Deliberately not stored: plan §3a has no table for
  it, roster ownership only matters for resolving *this request's*
  trade-resolved board, and it changes rarely enough that a live fetch (one
  call) is simpler than adding a table plus a staleness story for it. A
  roster with no `owner_id` (an empty/orphaned roster) is dropped rather
  than crashing the map build.
  """
  @spec fetch_roster_owners(integer | String.t()) :: {:ok, %{integer => integer}} | {:error, term}
  def fetch_roster_owners(league_id) do
    case Sleeper.get("/league/#{league_id}/rosters") do
      {:ok, rosters} ->
        owners =
          rosters
          |> Enum.filter(& &1["owner_id"])
          |> Map.new(fn r -> {r["roster_id"], to_int(r["owner_id"])} end)

        {:ok, owners}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Live `slot -> roster_id` for one draft, via `GET /draft/:id` — deliberately
  not read from the stored `observed_drafts.slot_to_roster_id` column.

  `GET /user/:id/drafts/nfl/:season` (what `CrawlLeaguemateDrafts` reads to
  discover and store a leaguemate's drafts) doesn't include
  `slot_to_roster_id` at all — confirmed against the harvested corpus
  (`test/support/corpus/rookie_drafts.json` has no such key on any entry,
  while `GET /draft/:id`'s own payload, `test/support/corpus/d13.json`,
  does). So a draft the crawler has only ever seen via that listing call —
  which is every `"complete"` draft once it stops being refreshed — has
  `slot_to_roster_id: nil` in the DB forever, and
  `PickOwnership.resolve_roster/5` needs an authoritative mapping to
  resolve pick ownership. This fetches it fresh for the one draft being
  analyzed, same request-scoped live-fetch pattern as
  `fetch_roster_owners/1` above (one extra call, no new table), rather than
  trusting whatever's stored.

  Also persists the fetched map onto the `observed_drafts` row (keyed on
  `id`, replacing only `slot_to_roster_id`) — the column already exists and
  is otherwise dead for any draft the crawler found via the listing call, so
  this is a cheap opportunistic backfill: once a draft has been analyzed
  once, later reads of the stored row (if anything ever needs one) see the
  real mapping too.
  """
  @spec fetch_slot_to_roster_id(integer) :: {:ok, %{integer => integer}} | {:error, term}
  def fetch_slot_to_roster_id(draft_id) do
    case Sleeper.get("/draft/#{draft_id}") do
      {:ok, response} ->
        raw = Map.get(response, "slot_to_roster_id") || %{}
        persist_slot_to_roster_id(draft_id, raw)
        {:ok, normalize_slot_map(raw)}

      {:error, _} = error ->
        error
    end
  end

  defp persist_slot_to_roster_id(draft_id, slot_to_roster_id) do
    insert_all_batched(
      ObservedDraft,
      [%{id: draft_id, slot_to_roster_id: slot_to_roster_id}],
      conflict_target: [:id],
      replace: [:slot_to_roster_id]
    )
  end

  @doc """
  `%{player_id => %{name, position}}` for a set of Sleeper player ids,
  joined from the `players` table (populated by the nightly
  `GetSleeperPlayerData` job, per plan §3f step 4 "should come from the
  existing players table — join, don't re-fetch"). A player id with no
  matching row is simply absent from the result; callers treat that as
  `name: nil, position: nil`.
  """
  @spec player_lookup([String.t()]) :: %{
          String.t() => %{name: String.t() | nil, position: String.t() | nil}
        }
  def player_lookup(player_ids) do
    from(p in SleeperPlayerApi.Sleeper.Player,
      left_join: pos in SleeperPlayerApi.Sleeper.Position,
      on: pos.id == p.position_id,
      where: p.player_id in ^player_ids,
      select: {p.player_id, %{name: p.full_name, position: pos.abbreviation}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @fantasy_positions ~w(QB RB WR TE)

  @doc """
  Which of `player_ids` play a standard fantasy-relevant position
  (#{inspect(@fantasy_positions)}), per the `players` table.

  Feeds `SleeperPlayerApi.Intel.Availability`'s `eligible_ids` — a corpus
  rookie draft's pick pool isn't exclusively skill positions (IDP/deep
  bench flyers get picked too), and without this filter a thin-sample
  non-fantasy player can out-rank every real target purely on raw ADP (see
  the report on this step for the concrete example this was found against).
  """
  @spec fantasy_position_ids([String.t()]) :: MapSet.t(String.t())
  def fantasy_position_ids(player_ids) do
    from(p in SleeperPlayerApi.Sleeper.Player,
      join: pos in SleeperPlayerApi.Sleeper.Position,
      on: pos.id == p.position_id,
      where: p.player_id in ^player_ids and pos.abbreviation in ^@fantasy_positions,
      select: p.player_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Every stored pick of a `"complete"` draft for any of `player_ids`,
  formatted `"round.slot@overall"` (plan §4e "store every individual
  pick... so the UI can show receipts") and grouped by `{manager,
  player_id}`, ascending by `pick_no` within each group.

  A second, small query rather than folding into `drafts_corpus/2`: the
  estimator-shaped corpus deliberately carries only the normalized pick
  (`Estimator` doesn't need `round`/`draft_slot`/`pick_no`), so this is the
  one place that reads them back out for display.
  """
  @spec manager_pick_strings([String.t()], %{integer => String.t()}) :: %{
          {String.t(), String.t()} => [String.t()]
        }
  def manager_pick_strings(player_ids, user_id_to_manager) do
    from(p in ObservedPick,
      join: d in ObservedDraft,
      on: d.id == p.draft_id,
      where: d.status == "complete" and p.player_id in ^player_ids and not is_nil(p.picked_by),
      order_by: [asc: p.pick_no],
      select: %{
        player_id: p.player_id,
        picked_by: p.picked_by,
        round: p.round,
        draft_slot: p.draft_slot,
        pick_no: p.pick_no
      }
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      case Map.get(user_id_to_manager, row.picked_by) do
        nil ->
          acc

        manager ->
          formatted = "#{row.round}.#{row.draft_slot}@#{row.pick_no}"
          Map.update(acc, {manager, row.player_id}, [formatted], &(&1 ++ [formatted]))
      end
    end)
  end

  @doc """
  The `/availability` endpoint's context entry point (plan §3f step 4).
  Trade-resolves `draft_id`'s remaining picks and, for every corpus player
  still on the board, its Kaplan-Meier survival curve conditioned on that
  board — see `SleeperPlayerApi.Intel.Availability` for the response shape
  and `SleeperPlayerApi.Intel.PickOwnership` for the resolution itself.

  `opts`:

    * `:user_id` (required) — whose remaining picks are "mine"
    * `:at_pick` — analyze as if the draft were currently at this pick
      instead of its actual next open one (plan §3g hypotheticals).
      Defaults to the draft's actual next pick.
    * `:limit` — how many corpus players become `targets` (default 20, or
      the length of `:player_ids` when that is given)
    * `:player_ids` — restrict `targets` to these players (plan §6 step 3).
      See "Caller-chosen targets" below.

  ## Caller-chosen targets

  Without `:player_ids` this picks the targets itself: every corpus player
  still on the board, ordered by league ADP, capped at `:limit`. That is a
  reasonable default for a caller with no opinion, but the frontend has
  one — "Best Available" means *the user's own rank list* everywhere else
  in that app, so it asks about exactly those players and joins the answer
  onto rows it is already rendering.

  Two consequences worth being explicit about, because both are deliberate:

    * **Explicit ids replace the internal eligibility filters** rather than
      intersecting with them. `eligible_ids/1`'s position and market
      filters exist to stop a thin-sample junk player out-ranking real
      targets when 20 are being *selected* from a pool of hundreds. When
      the caller names the players, nothing is being selected and that
      pressure is gone — so filtering further could only drop a player the
      caller explicitly asked about, and the caller cannot tell that
      "absent" from "the corpus has never seen him".
    * **Corpus membership still applies.** A player nobody in the circle
      has ever drafted has no survival curve to compute and is silently
      absent from `targets` at any limit. That is the honest "no read"
      case, and the caller renders it as such.

  The default of `:limit` follows `:player_ids` so that asking about a
  40-player rank list doesn't silently answer for 20 of them.

  Refreshes the draft's own picks/traded_picks first when it isn't stored
  yet or its stored status is `"drafting"`, via
  `SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts.refresh_draft/1` — reusing
  the crawler's own fetch path rather than a second one, per the plan's
  scope note. A `"complete"` draft is immutable and is never refetched. If
  a refresh attempt fails but the draft was already stored, the stale
  stored copy is used rather than failing the whole request.

  Returns `{:ok, response}`, `{:error, :draft_not_found}` if `draft_id`
  isn't stored and can't be fetched from Sleeper either, or `{:error,
  reason}` from `Availability.build/1` (an unresolvable draft type — see
  its moduledoc on why that's a hard failure rather than a degraded
  response).
  """
  @spec availability(integer | String.t(), keyword) :: {:ok, map} | {:error, term}
  def availability(draft_id, opts \\ []) do
    draft_id = to_int(draft_id)
    my_user_id = opts |> Keyword.fetch!(:user_id) |> to_int()
    at_pick = opts[:at_pick]
    player_ids = opts[:player_ids]
    limit = Keyword.get(opts, :limit) || default_limit(player_ids)

    with :ok <- ensure_fresh(draft_id) do
      case get_observed_draft(draft_id) do
        nil -> {:error, :draft_not_found}
        draft -> build_availability(draft, my_user_id, at_pick, limit, player_ids)
      end
    end
  end

  # A caller naming its players wants an answer about all of them, not the
  # 20 of them with the earliest league ADP — see "Caller-chosen targets".
  defp default_limit(nil), do: 20
  defp default_limit(player_ids), do: length(player_ids)

  defp ensure_fresh(draft_id) do
    case get_observed_draft(draft_id) do
      nil -> refresh(draft_id)
      %ObservedDraft{status: "drafting"} -> refresh(draft_id)
      %ObservedDraft{} -> :ok
    end
  end

  defp refresh(draft_id) do
    case SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts.refresh_draft(draft_id) do
      {:ok, _summary} -> :ok
      {:error, reason} -> if get_observed_draft(draft_id), do: :ok, else: {:error, reason}
    end
  end

  defp build_availability(draft, my_user_id, at_pick, limit, player_ids) do
    picks_made = draft_picks(draft.id)
    traded_picks = draft_traded_picks(draft.id)

    with {:ok, slot_to_roster_id} <- fetch_slot_to_roster_id(draft.id),
         {:ok, roster_to_user} <- fetch_roster_owners(draft.league_id) do
      user_id_to_manager = manager_names_by_id()
      corpus = drafts_corpus(user_id_to_manager, exclude_draft_id: draft.id)

      already_picked =
        picks_made |> Enum.map(& &1.player_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

      candidate_ids =
        for d <- corpus, p <- d.picks, not MapSet.member?(already_picked, p.player_id) do
          p.player_id
        end
        |> Enum.uniq()

      Availability.build(%{
        league_name: draft.league_name,
        draft_id: draft.id,
        teams: draft.teams,
        rounds: draft.rounds,
        draft_type: draft.draft_type,
        slot_to_roster_id: slot_to_roster_id,
        picks_made: picks_made,
        traded_picks: traded_picks,
        roster_to_user: roster_to_user,
        user_id_to_manager: user_id_to_manager,
        my_user_id: my_user_id,
        at_pick: at_pick,
        limit: limit,
        corpus: corpus,
        candidate_lookup: player_lookup(candidate_ids),
        market_rank: Estimator.rookie_class_rank(market_rookie_class_entries(draft.season)),
        raw_picks: manager_pick_strings(candidate_ids, user_id_to_manager),
        eligible_ids: eligible_ids(candidate_ids, player_ids)
      })
    end
  end

  # `player_values` (plan §2/§3a) is populated by
  # `SleeperPlayerApi.Tasks.RefreshPlayerValues` (plan §3f step 5) — not
  # this module. Filters to the rookie class for `draft.season`: entries
  # whose `draft_year` matches, per estimator §8 ("rank within the ROOKIE
  # CLASS... not overall rank"). `draft.season` is a string ("2026", as
  # Sleeper sends it); `draft_year` is stored as an integer (from
  # FantasyCalc's `maybeDraftInfo.year`), so the comparison converts.
  #
  # Until `RefreshPlayerValues` has run — or for a season it hasn't covered
  # — this returns `[]`, which flows through to `Estimator.rookie_class_rank/1`
  # returning `%{}`, so `marketPick`/`adpGap` come back `nil` for every
  # target: an honest "no market read yet", not a fabricated one.
  #
  # NOT the same set `eligible_ids/1` below restricts targets to — see its
  # comment. Three of the fixture's own 16 targets (Justin Joly, Michael
  # Trigg, J'Mari Taylor) are in FantasyCalc's payload with no
  # `maybeDraftInfo` at all, so they're absent here (no `marketPick`) but
  # must still be eligible targets.
  defp market_rookie_class_entries(nil), do: []

  defp market_rookie_class_entries(season) do
    case Integer.parse(season) do
      {year, _} ->
        from(pv in PlayerValue,
          where: pv.source == "fantasycalc" and pv.draft_year == ^year,
          select: {pv.player_id, pv.value}
        )
        |> Repo.all()
        |> Enum.map(fn {player_id, value} -> {to_string(player_id), value} end)

      :error ->
        []
    end
  end

  # Every player id FantasyCalc tracks at all — source `"fantasycalc"`,
  # regardless of `draft_year`. Deliberately broader than
  # `market_rookie_class_entries/1`: "FantasyCalc's tracked rookie universe"
  # (plan §3f step 5 item 5) means "FantasyCalc has *an opinion* on this
  # player", not "FantasyCalc classifies him as this season's rookie class"
  # — verified against the fixture, whose Joly/Trigg/Taylor entries have no
  # `maybeDraftInfo` (so no `marketPick`) but are still present in
  # FantasyCalc's payload and still targets.
  defp market_universe_ids do
    from(pv in PlayerValue, where: pv.source == "fantasycalc", select: pv.player_id)
    |> Repo.all()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  # Which corpus players are eligible to become `targets` (plan §3f step 5
  # item 5 — "complete the deferred targets restriction"). Two filters,
  # applied together once market data exists:
  #
  #   1. fantasy-relevant position (already built in step 4 — a rookie
  #      draft's pool isn't exclusively QB/RB/WR/TE)
  #   2. present in FantasyCalc's tracked universe at all (new here) — a
  #      player with no market value shouldn't be a target. This is what
  #      fixes the production case in the report: a one-draft, one-manager
  #      sample ("Kyle Dixon, WR, lgADP 34.0, sd 0.0, n 1") was outranking
  #      real targets purely on a thin ADP sample with nothing else backing
  #      it up.
  #
  # Degradation is deliberate: if `market_universe_ids/0` is empty (no
  # refresh has run yet), filter 2 is skipped entirely rather than
  # intersecting against an empty set — which would zero out `targets`
  # completely. That keeps `/availability` working exactly as it did before
  # this step for anyone who hasn't run `RefreshPlayerValues` yet, which is
  # also why the existing acceptance tests (no `player_values` seeded) pass
  # unchanged.
  # When the caller named its own players, that set *is* the eligibility —
  # both filters below are selection aids, and nothing is being selected.
  # See `availability/2`'s "Caller-chosen targets".
  defp eligible_ids(_candidate_ids, player_ids) when is_list(player_ids),
    do: MapSet.new(player_ids)

  defp eligible_ids(candidate_ids, nil), do: eligible_ids(candidate_ids)

  defp eligible_ids(candidate_ids) do
    position_ids = fantasy_position_ids(candidate_ids)
    market_ids = market_universe_ids()

    if MapSet.size(market_ids) == 0 do
      position_ids
    else
      MapSet.intersection(position_ids, market_ids)
    end
  end

  # ---------------------------------------------------------------------
  # `/intel` (plan §3e, §3f step 5)
  # ---------------------------------------------------------------------

  @doc """
  Builds the `GET /api/v1/leagues/:league_id/intel` response (plan §3e):

      %{managers: [%{user_id, display_name, leagues_count, drafts_count,
                      drafts_complete, tendencies}],
        corpus: %{drafts, picks, last_crawled_at, membership_source}}

  ## Who counts as a "manager" of this league?

  Every member of the *live* Sleeper league, via `GET /league/:id/users` —
  the same call `CrawlLeaguemateDrafts` already makes, and the same
  request-scoped live-fetch pattern `fetch_roster_owners/1` uses for
  `/availability`. This is deliberately **not** derived from
  `observed_picks` or `draft_participants`: both only know about managers
  who have actually picked in an *observed* draft, so a leaguemate sitting
  out this year's rookie draft (0 drafts seen) would silently vanish from
  the list entirely — exactly backwards from what the frontend needs. Plan
  §3 Frontend is explicit that a 0-draft manager must still render, as
  "league average · none of their drafts seen", not disappear. See the
  report on this step for the two production leaguemates this fixes.

  `draft_participants` (now populated, see `Intel.upsert_observed_picks/2`)
  does NOT fix this on its own — it records draft *participation*, and a
  leaguemate who has never drafted appears in no participation table
  either. League *membership* is a different fact than participation, and
  `GET /league/:id/users` is its only authoritative source.

  A member's `display_name` comes from the live response itself (falling
  back to the stored `sleeper_users` row if Sleeper ever returns one with a
  blank name); nothing here writes back to `sleeper_users` — that table's
  writer stays `CrawlLeaguemateDrafts.store_users/1`, keeping "who crawls
  writes it" a single rule.

  **Failure behaviour.** If the live call fails (Sleeper down, bad
  `league_id`, rate limited), this falls back to the old derived set —
  every user_id with at least one observed pick in one of this league's own
  stored drafts, via `manager_ids_for_league/2` — rather than failing the
  whole request: `/intel` is a browse view, not a survival number, so a
  degraded-but-present response is more useful than a 5xx. That degradation
  is never silent, though: it's logged, and `corpus.membership_source` in
  the response is `"live"` or `"derived"` so a caller (or a future UI badge)
  can tell a complete membership list from a possibly-incomplete one rather
  than the response looking equally authoritative either way.

  If neither the live call nor any stored draft exists for this league,
  `managers` comes back `[]` — an honest "nothing known about this league",
  not an error.

  ## `leagues_count` / `drafts_count` / `drafts_complete`

  These are **not** scoped to `league_id` — they're the manager's totals
  across the *entire* stored corpus (every league/draft they've ever been
  observed in), matching plan §5's "how many leagues / rookie drafts is he
  in? — free, it's just a count over the data already harvested." Scoping
  them to one league would make every manager read "1 league, 1 draft",
  which isn't the question this field answers.

  ## `tendencies`

  Loosely specified by plan §4c (player crushes) and §0 (positional lean,
  reach vs ADP) — implemented here as exactly what falls out of
  `observed_picks` as `GROUP BY` aggregates, no fitted model:

    * `crushes` — this manager's top 5 most-repeated players, by raw pick
      count, across every complete draft they're observed in (plan §4c).
    * `position_lean` — the share of their picks at each position
      (QB/RB/WR/TE — the same `players`-table join `fantasy_position_ids/1`
      uses), sorted by share descending.
    * `reach_vs_adp` — mean `(league ADP − their own ADP)` across every
      player they've drafted at least once, restricted to players the wider
      corpus has seen at least twice (`n >= 2`) so a single other manager's
      one-off pick can't define "league ADP" for the comparison. Positive
      means this manager takes players earlier than the corpus average
      (a reacher); negative means they let players slide. `nil` if nothing
      clears the `n >= 2` bar.

  Deliberately NOT built: a fitted "how chalky" score or roster-construction
  read (plan §0's "roster construction" bullet) — both need a model or a
  live rosters call this step doesn't reach for; see the report on this
  step.
  """
  @spec league_intel(integer | String.t(), keyword) :: map
  def league_intel(league_id, opts \\ []) do
    league_id = to_int(league_id)
    season = opts[:season]
    names = manager_names_by_id()

    {member_pairs, membership_source} = league_membership(league_id, season, names)

    managers =
      member_pairs
      |> Enum.map(fn {user_id, display_name} ->
        stats = manager_corpus_stats(user_id)

        %{
          user_id: user_id,
          display_name: display_name,
          leagues_count: stats.leagues_count,
          drafts_count: stats.drafts_count,
          drafts_complete: stats.drafts_complete,
          tendencies: manager_tendencies(user_id)
        }
      end)
      |> Enum.sort_by(&(&1.display_name || ""))

    %{
      managers: managers,
      corpus: Map.put(corpus_summary(), :membership_source, membership_source)
    }
  end

  # `{[{user_id, display_name}], :live | :derived}` — see `league_intel/2`'s
  # "Failure behaviour" doc for why the fallback exists and why it's not
  # silent.
  defp league_membership(league_id, season, names) do
    case fetch_league_members(league_id) do
      {:ok, members} ->
        pairs =
          Enum.map(members, fn m -> {m.user_id, m.display_name || Map.get(names, m.user_id)} end)

        {pairs, :live}

      {:error, reason} ->
        Logger.warning(
          "Intel.league_intel: live GET /league/#{league_id}/users failed (#{inspect(reason)}); " <>
            "falling back to observed_picks-derived membership"
        )

        pairs =
          league_id
          |> manager_ids_for_league(season)
          |> Enum.map(fn user_id -> {user_id, Map.get(names, user_id)} end)

        {pairs, :derived}
    end
  end

  @doc """
  Live league membership via `GET /league/:id/users` — the authoritative
  source for "who is in this league" (see `league_intel/2`'s moduledoc
  section on why `observed_picks`/`draft_participants` can't answer this).
  Deliberately not persisted anywhere here; see that same doc.
  """
  @spec fetch_league_members(integer | String.t()) ::
          {:ok, [%{user_id: integer, display_name: String.t() | nil}]} | {:error, term}
  def fetch_league_members(league_id) do
    case Sleeper.get("/league/#{league_id}/users") do
      {:ok, users} ->
        members =
          Enum.map(users, fn u ->
            %{user_id: to_int(u["user_id"]), display_name: u["display_name"]}
          end)

        {:ok, members}

      {:error, _} = error ->
        error
    end
  end

  # The pre-Gap-2 derivation, kept only as the fallback `league_membership/3`
  # reaches for when the live call fails: every user_id with at least one
  # observed pick in one of this league's own stored drafts, optionally
  # narrowed to `season`. This is participation, not membership — it will
  # never surface a 0-draft manager, which is the exact gap the live call
  # exists to close. Reads `draft_participants` rather than `GROUP BY`-ing
  # `observed_picks` directly, same reasoning as `manager_drafts_seen/0`.
  defp manager_ids_for_league(league_id, season) do
    base =
      from(dp in DraftParticipant,
        join: d in ObservedDraft,
        on: d.id == dp.draft_id,
        where: d.league_id == ^league_id
      )

    query = if season, do: from([dp, d] in base, where: d.season == ^season), else: base

    query
    |> distinct(true)
    |> select([dp, _d], dp.user_id)
    |> Repo.all()
  end

  # Corpus-wide totals for one manager — NOT scoped to any one league (see
  # `league_intel/2`'s doc on `leagues_count`/`drafts_count`/`drafts_complete`).
  # Reads `draft_participants` rather than `GROUP BY`-ing `observed_picks`
  # directly, per plan §3a's rationale for the table; a user_id with no
  # participation rows at all (a live-membership manager with 0 observed
  # drafts, Gap 2's whole point) correctly comes back all zeros rather than
  # `nil`, since `count(...)` over an empty match set is `0` in Postgres.
  defp manager_corpus_stats(user_id) do
    from(dp in DraftParticipant,
      join: d in ObservedDraft,
      on: d.id == dp.draft_id,
      where: dp.user_id == ^user_id,
      select: %{
        leagues_count: count(d.league_id, :distinct),
        drafts_count: count(d.id, :distinct),
        drafts_complete:
          fragment("count(distinct case when ? = 'complete' then ? end)", d.status, d.id)
      }
    )
    |> Repo.one()
  end

  defp corpus_summary do
    drafts =
      Repo.one(from(d in ObservedDraft, where: d.status == "complete", select: count(d.id))) || 0

    picks =
      Repo.one(
        from(p in ObservedPick,
          join: d in ObservedDraft,
          on: d.id == p.draft_id,
          where: d.status == "complete",
          select: count(p.pick_no)
        )
      ) || 0

    last_crawled_at = Repo.one(from(d in ObservedDraft, select: max(d.picks_fetched_at)))

    %{drafts: drafts, picks: picks, last_crawled_at: last_crawled_at}
  end

  defp manager_tendencies(user_id) do
    %{
      crushes: manager_crushes(user_id),
      position_lean: manager_position_lean(user_id),
      reach_vs_adp: manager_reach_vs_adp(user_id)
    }
  end

  @crush_limit 5

  defp manager_crushes(user_id) do
    rows =
      from(p in ObservedPick,
        join: d in ObservedDraft,
        on: d.id == p.draft_id,
        where: p.picked_by == ^user_id and d.status == "complete",
        group_by: p.player_id,
        order_by: [desc: count(p.pick_no)],
        limit: ^@crush_limit,
        select: %{player_id: p.player_id, times: count(p.pick_no)}
      )
      |> Repo.all()

    seen = Map.get(manager_drafts_seen(), user_id, 0)
    lookup = player_lookup(Enum.map(rows, & &1.player_id))

    Enum.map(rows, fn row ->
      info = Map.get(lookup, row.player_id, %{})

      %{
        player_id: row.player_id,
        name: Map.get(info, :name),
        position: Map.get(info, :position),
        times: row.times,
        of: seen
      }
    end)
  end

  defp manager_position_lean(user_id) do
    rows =
      from(p in ObservedPick,
        join: d in ObservedDraft,
        on: d.id == p.draft_id,
        join: pl in SleeperPlayerApi.Sleeper.Player,
        on: pl.player_id == p.player_id,
        join: pos in SleeperPlayerApi.Sleeper.Position,
        on: pos.id == pl.position_id,
        where: p.picked_by == ^user_id and d.status == "complete",
        group_by: pos.abbreviation,
        select: {pos.abbreviation, count(p.pick_no)}
      )
      |> Repo.all()

    total = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total == 0 do
      []
    else
      rows
      |> Enum.map(fn {position, n} ->
        %{position: position, picks: n, share: Float.round(n / total, 3)}
      end)
      |> Enum.sort_by(&(-&1.picks))
    end
  end

  defp manager_reach_vs_adp(user_id) do
    own_adp =
      from(p in ObservedPick,
        join: d in ObservedDraft,
        on: d.id == p.draft_id,
        where: p.picked_by == ^user_id and d.status == "complete",
        group_by: p.player_id,
        select: %{
          player_id: p.player_id,
          own_adp: avg(fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams))
        }
      )
      |> Repo.all()

    league = league_adp_batch(Enum.map(own_adp, & &1.player_id))

    deltas =
      for %{player_id: player_id, own_adp: mine} <- own_adp,
          %{n: n, adp: league_adp} <- [Map.get(league, player_id)],
          not is_nil(n) and n >= 2 do
        league_adp - mine
      end

    case deltas do
      [] -> nil
      _ -> Float.round(Enum.sum(deltas) / length(deltas), 2)
    end
  end

  defp league_adp_batch([]), do: %{}

  defp league_adp_batch(player_ids) do
    from(p in ObservedPick,
      join: d in ObservedDraft,
      on: d.id == p.draft_id,
      where: p.player_id in ^player_ids,
      group_by: p.player_id,
      select: %{
        player_id: p.player_id,
        n: count(p.pick_no),
        adp: avg(fragment("((? - 1)::float / ? * 12) + 1", p.pick_no, d.teams))
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.player_id, &1})
  end

  defp normalize_slot_map(nil), do: %{}

  defp normalize_slot_map(slot_to_roster_id) do
    Map.new(slot_to_roster_id, fn {slot, roster_id} -> {to_int(slot), to_int(roster_id)} end)
  end

  defp to_int(nil), do: nil
  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
end
