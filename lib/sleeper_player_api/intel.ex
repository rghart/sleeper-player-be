defmodule SleeperPlayerApi.Intel do
  @moduledoc """
  Context for the leaguemate-intel corpus: storing the Sleeper drafts/picks
  harvested by the (not-yet-built, see `docs/leaguemate-intel.md` §3f steps
  2-3) crawler, and shaping what's stored back out into the plain-map input
  `SleeperPlayerApi.Intel.Estimator` expects.

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
  call (see its doc) and, for an in-progress draft, a refresh through
  `SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts.refresh_draft/1`.
  """

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel.{Estimator, Availability}

  alias SleeperPlayerApi.Intel.{
    SleeperUser,
    ObservedDraft,
    ObservedPick,
    ObservedTradedPick,
    PlayerValue,
    DraftParticipant
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
  """
  @spec upsert_observed_picks(integer, [map]) :: {non_neg_integer, nil}
  def upsert_observed_picks(draft_id, picks) do
    picks
    |> Enum.map(&Map.put(&1, :draft_id, draft_id))
    |> then(
      &insert_all_batched(
        ObservedPick,
        &1,
        conflict_target: [:draft_id, :pick_no],
        replace: [:round, :draft_slot, :roster_id, :player_id, :picked_by]
      )
    )
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
      replace: [:value, :overall_rank, :position_rank, :roster_percent, :trade_frequency, :as_of]
    )
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
  `%{picked_by => count of distinct drafts}` across every stored pick —
  "how many drafts have we observed this manager in at all", the `seen_m`
  input to the estimator's manager multiplier (§6). Managers with `nil`
  `picked_by` (not a tracked leaguemate) are excluded.
  """
  @spec manager_drafts_seen() :: %{integer => non_neg_integer}
  def manager_drafts_seen do
    from(p in ObservedPick,
      where: not is_nil(p.picked_by),
      group_by: p.picked_by,
      select: {p.picked_by, count(p.draft_id, :distinct)}
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
    * `:limit` — how many corpus players become `targets` (default 20)

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
    limit = Keyword.get(opts, :limit, 20)

    with :ok <- ensure_fresh(draft_id) do
      case get_observed_draft(draft_id) do
        nil -> {:error, :draft_not_found}
        draft -> build_availability(draft, my_user_id, at_pick, limit)
      end
    end
  end

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

  defp build_availability(draft, my_user_id, at_pick, limit) do
    picks_made = draft_picks(draft.id)
    traded_picks = draft_traded_picks(draft.id)
    slot_to_roster_id = normalize_slot_map(draft.slot_to_roster_id)

    with {:ok, roster_to_user} <- fetch_roster_owners(draft.league_id) do
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
        market_rank: Estimator.rookie_class_rank(market_rookie_class_entries()),
        raw_picks: manager_pick_strings(candidate_ids, user_id_to_manager),
        eligible_ids: fantasy_position_ids(candidate_ids)
      })
    end
  end

  # `player_values` (plan §2/§3a) is refreshed from FantasyCalc by plan §3f
  # step 5, which this endpoint step deliberately doesn't build (scope
  # note: "NOT /intel — that's step 5"). Until that refresh job runs, this
  # is always empty, so `marketPick`/`adpGap` come back `nil` for every
  # target — an honest "no market read yet", not a fabricated one.
  # `maybeDraftInfo.year` (the rookie-class filter, estimator §8) isn't a
  # `player_values` column either; extending that schema is step 5's job.
  defp market_rookie_class_entries do
    from(pv in PlayerValue,
      where: pv.source == "fantasycalc",
      select: {pv.player_id, pv.value}
    )
    |> Repo.all()
    |> Enum.map(fn {player_id, value} -> {to_string(player_id), value} end)
  end

  defp normalize_slot_map(nil), do: %{}

  defp normalize_slot_map(slot_to_roster_id) do
    Map.new(slot_to_roster_id, fn {slot, roster_id} -> {to_int(slot), to_int(roster_id)} end)
  end

  defp to_int(nil), do: nil
  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
end
