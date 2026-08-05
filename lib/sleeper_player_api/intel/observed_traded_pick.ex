defmodule SleeperPlayerApi.Intel.ObservedTradedPick do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedDraft

  @primary_key false
  schema "observed_traded_picks" do
    belongs_to :draft, ObservedDraft, references: :id
    field :season, :string
    field :round, :integer
    field :roster_id, :integer
    field :previous_owner_id, :integer
    field :owner_id, :integer

    timestamps()
  end

  @doc false
  def changeset(observed_traded_pick, attrs) do
    observed_traded_pick
    |> cast(attrs, [:draft_id, :season, :round, :roster_id, :previous_owner_id, :owner_id])
    |> validate_required([:draft_id, :season, :round, :roster_id])
    |> unique_constraint([:draft_id, :season, :round, :roster_id])
  end
end
