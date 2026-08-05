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

  No HTTP, no crawler, no controllers here — see plan §3f step 1.
  """

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Repo

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
  """
  @spec drafts_corpus(%{integer => String.t()}) :: [map]
  def drafts_corpus(user_id_to_manager \\ %{}) do
    teams_by_draft =
      from(d in ObservedDraft, select: {d.id, d.teams})
      |> Repo.all()
      |> Map.new()

    picks_by_draft =
      from(p in ObservedPick, order_by: [asc: p.draft_id, asc: p.pick_no])
      |> Repo.all()
      |> Enum.group_by(& &1.draft_id)

    for {draft_id, picks} <- picks_by_draft, picks != [] do
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
end
