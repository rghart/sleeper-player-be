defmodule SleeperPlayerApi.Intel.DraftParticipant do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.{ObservedDraft, SleeperUser}

  @primary_key false
  schema "draft_participants" do
    belongs_to :draft, ObservedDraft, references: :id
    belongs_to :user, SleeperUser, references: :id

    timestamps()
  end

  @doc false
  def changeset(draft_participant, attrs) do
    draft_participant
    |> cast(attrs, [:draft_id, :user_id])
    |> validate_required([:draft_id, :user_id])
    |> unique_constraint([:draft_id, :user_id])
  end
end
