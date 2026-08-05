defmodule SleeperPlayerApi.Intel.ObservedPick do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedDraft

  @primary_key false
  schema "observed_picks" do
    belongs_to :draft, ObservedDraft, references: :id
    field :pick_no, :integer
    field :round, :integer
    field :draft_slot, :integer
    field :roster_id, :integer
    field :player_id, :string
    field :picked_by, :integer

    timestamps()
  end

  @doc false
  def changeset(observed_pick, attrs) do
    observed_pick
    |> cast(attrs, [:draft_id, :pick_no, :round, :draft_slot, :roster_id, :player_id, :picked_by])
    |> validate_required([:draft_id, :pick_no])
    |> unique_constraint([:draft_id, :pick_no])
  end
end
