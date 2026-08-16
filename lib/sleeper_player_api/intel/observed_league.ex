defmodule SleeperPlayerApi.Intel.ObservedLeague do
  @moduledoc """
  A league one of the tracked leaguemates is in (plan §6 step 6).

  Wider than `observed_drafts`' league coverage on purpose: that only knows
  the leagues that happened to have a completed rookie draft (70), where
  enumerating per user reaches every league they are in (176 measured).

  `roster_to_user` is why this is a table rather than a derived value. A
  transaction payload carries `creator` as a user id and `roster_ids` /
  `consenter_ids` as roster ids, so attributing a trade to the manager who
  *accepted* it needs this map — and re-deriving it would mean re-fetching
  `/league/:id/rosters` for every league on every crawl.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: false}
  schema "observed_leagues" do
    field :name, :string
    field :season, :string
    # %{"roster_id" => user_id}. String keys because it round-trips as jsonb.
    field :roster_to_user, :map
    field :rosters_fetched_at, :utc_datetime
    field :transactions_fetched_through, :integer

    # Sleeper's own `settings.waiver_budget` / `settings.waiver_type`, kept
    # out of the league objects the enumeration already returns. A bid is
    # meaningless without the budget it was made against, and a zero is
    # meaningless without knowing whether the league bids at all — see the
    # migration for the measured spread. `waiver_type` 2 is FAAB.
    field :waiver_budget, :integer
    field :waiver_type, :integer

    timestamps()
  end

  @doc false
  def changeset(observed_league, attrs) do
    observed_league
    |> cast(attrs, [
      :id,
      :name,
      :season,
      :roster_to_user,
      :rosters_fetched_at,
      :transactions_fetched_through,
      :waiver_budget,
      :waiver_type
    ])
    |> validate_required([:id])
  end
end
