defmodule SleeperPlayerApi.Market do
  @moduledoc """
  The market draft corpus: completed dynasty drafts from across Sleeper,
  stored with their format, for ADP from real drafts (docs/dynasty-engine.md,
  M3). Written by `Tasks.CrawlMarketDrafts`; read by the ADP calculation.

  Kept apart from the leaguemate corpus in `SleeperPlayerApi.Intel` on
  purpose; see the `create_market_corpus` migration for why.
  """

  import Ecto.Query, warn: false

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Market.{Draft, Format, League, Pick, User}

  # ---------------------------------------------------------------------
  # Frontier
  # ---------------------------------------------------------------------

  @doc """
  Adds users to the frontier at `depth`. A user already there keeps the depth
  they were first found at, which is their shortest path from a seed.
  """
  @spec add_users([integer | String.t()], non_neg_integer) :: non_neg_integer
  def add_users(user_ids, depth) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      user_ids
      |> Enum.map(&to_int/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&%{id: &1, depth: depth, inserted_at: now, updated_at: now})

    rows
    |> Enum.chunk_every(1000)
    |> Enum.reduce(0, fn chunk, total ->
      {n, _} = Repo.insert_all(User, chunk, on_conflict: :nothing, conflict_target: [:id])
      total + n
    end)
  end

  @doc """
  The next users to crawl: never-crawled first (nearest seeds first), then
  those last crawled before `revisit_before`, oldest first.
  """
  @spec next_users(pos_integer, DateTime.t()) :: [User.t()]
  def next_users(limit, revisit_before) do
    from(u in User,
      where: is_nil(u.crawled_at) or u.crawled_at < ^revisit_before,
      order_by: [asc_nulls_first: u.crawled_at, asc: u.depth, asc: u.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Marks a user crawled now."
  def mark_user_crawled(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from(u in User, where: u.id == ^to_int(user_id)) |> Repo.update_all(set: [crawled_at: now])
    :ok
  end

  @doc "How many users are on the frontier, and how many of them are still uncrawled."
  def frontier_size do
    Repo.one(from(u in User, select: {count(u.id), count(u.id) |> filter(is_nil(u.crawled_at))}))
  end

  # ---------------------------------------------------------------------
  # Leagues
  # ---------------------------------------------------------------------

  @doc "A stored league, or nil."
  def get_league(league_id), do: Repo.get(League, to_int(league_id))

  @doc "Stores a league's format from Sleeper's league object, and returns it."
  def put_league(league) do
    attrs = %{
      id: to_int(league["league_id"]),
      season: league["season"],
      league_type: get_in(league, ["settings", "type"]),
      te_premium: number(get_in(league, ["scoring_settings", "bonus_rec_te"])) || 0.0,
      ppr: number(get_in(league, ["scoring_settings", "rec"])),
      total_rosters: league["total_rosters"]
    }

    %League{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict:
        {:replace, [:season, :league_type, :te_premium, :ppr, :total_rosters, :updated_at]},
      conflict_target: [:id]
    )
  end

  @doc "Marks a league's users as added to the frontier."
  def mark_league_users_crawled(league_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(l in League, where: l.id == ^to_int(league_id))
    |> Repo.update_all(set: [users_crawled_at: now])

    :ok
  end

  # ---------------------------------------------------------------------
  # Drafts
  # ---------------------------------------------------------------------

  @doc "The ids among `draft_ids` already stored."
  def known_drafts(draft_ids) do
    ids = draft_ids |> Enum.map(&to_int/1) |> Enum.reject(&is_nil/1)
    from(d in Draft, where: d.id in ^ids, select: d.id) |> Repo.all() |> MapSet.new()
  end

  @doc """
  Stores a draft and its picks in one transaction. `attrs` are the draft's
  columns; `picks` Sleeper's `/draft/:id/picks` payload. Picks without a
  player, and keeper picks (a player kept rather than drafted), are not
  stored. `complete` is set when every slot was drafted with a player.
  """
  def store_draft(attrs, picks) do
    rows =
      for %{"pick_no" => pick_no, "player_id" => player_id} = pick <- picks,
          is_binary(player_id) and player_id != "",
          pick["is_keeper"] != true do
        %{draft_id: attrs.id, pick_no: pick_no, round: pick["round"], player_id: player_id}
      end

    expected = (attrs.teams || 0) * (attrs.rounds || 0)

    attrs =
      Map.merge(attrs, %{
        picks_count: length(rows),
        complete: expected > 0 and length(rows) == expected
      })

    Repo.transaction(fn ->
      %Draft{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!(on_conflict: :replace_all, conflict_target: [:id])

      from(p in Pick, where: p.draft_id == ^attrs.id) |> Repo.delete_all()
      rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Pick, &1))
      attrs
    end)
  end

  @doc """
  Complete drafts per format bucket that started at or after `since`, as
  `%{bucket => count}`, with every bucket present.
  """
  def bucket_counts(since) do
    counts =
      from(d in Draft,
        where: d.complete and d.started_at >= ^since,
        select: {d.kind, d.qb_slots, d.te_premium}
      )
      |> Repo.all()
      |> Enum.frequencies_by(fn {kind, qb, tep} -> Format.bucket(kind, qb, tep) end)

    Map.new(Format.buckets(), &{&1, Map.get(counts, &1, 0)})
  end

  @doc """
  The complete drafts in one format bucket that started at or after `since`,
  each with its picks: `[%{id, picks: [%{pick_no, player_id}]}]`, the shape
  `Market.Adp.compute/1` reads.
  """
  def bucket_drafts({kind, qb, tep}, since) do
    query =
      from(d in Draft,
        where: d.complete and d.kind == ^kind and d.started_at >= ^since,
        select: d.id
      )

    query =
      if qb == "sf",
        do: where(query, [d], d.qb_slots >= 2),
        else: where(query, [d], d.qb_slots < 2)

    query =
      if tep == "tep",
        do: where(query, [d], d.te_premium > 0.0),
        else: where(query, [d], is_nil(d.te_premium) or d.te_premium <= 0.0)

    ids = Repo.all(query)

    picks =
      from(p in Pick,
        where: p.draft_id in ^ids,
        select: {p.draft_id, %{pick_no: p.pick_no, player_id: p.player_id}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(ids, &%{id: &1, picks: Map.get(picks, &1, [])})
  end

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_), do: nil

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
