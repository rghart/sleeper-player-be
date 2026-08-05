defmodule SleeperPlayerApi.Intel.ObservedDraft do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: false}
  schema "observed_drafts" do
    field :league_id, :integer
    field :season, :string
    field :status, :string
    field :draft_type, :string
    field :player_type, :integer
    field :teams, :integer
    field :rounds, :integer
    field :start_time, :integer
    field :slot_to_roster_id, :map
    field :picks_fetched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(observed_draft, attrs) do
    observed_draft
    |> cast(attrs, [
      :id,
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
    ])
    |> validate_required([:id])
  end
end
