defmodule SleeperPlayerApi.Intel.ObservedRoster do
  @moduledoc """
  One roster in one observed league: its owner, and who is on it now.

  This is the half of `/league/:id/rosters` that `ObservedLeague` discards.
  `roster_to_user` is stable within a season, so the transactions crawler
  fetches it once; `players` is not — it moves with every trade, waiver and
  free-agent add — so this table is refreshed on every crawl.

  It exists to answer "how much of this player do your leaguemates own",
  which the rookie-draft corpus cannot: measured 2026-08-09, 94% of
  (manager, player) ownership pairs never appear in the corpus at all, and
  the managers with the least draft history have the most leagues.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedLeague

  @primary_key false
  schema "observed_rosters" do
    belongs_to :league, ObservedLeague, references: :id, type: :id, define_field: false
    field :league_id, :integer
    field :roster_id, :integer
    field :owner_id, :integer
    field :player_ids, {:array, :string}, default: []
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(observed_roster, attrs) do
    observed_roster
    |> cast(attrs, [:league_id, :roster_id, :owner_id, :player_ids, :fetched_at])
    |> validate_required([:league_id, :roster_id])
    |> unique_constraint([:league_id, :roster_id])
  end
end
