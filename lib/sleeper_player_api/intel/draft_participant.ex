defmodule SleeperPlayerApi.Intel.DraftParticipant do
  @moduledoc """
  `(draft_id, user_id)` participation join row — every distinct non-nil
  `picked_by` observed on a draft's picks (see `Intel.upsert_observed_picks/2`,
  which populates this table as a side effect of storing picks).

  `user_id` deliberately has no DB-level foreign key to `sleeper_users`
  (see `20260806140000_drop_draft_participants_user_fk.exs`): a draft pulled
  in via a leaguemate's *other* league is full of co-managers `sleeper_users`
  has never heard of (it's only ever populated from `GET /league/:id/users`
  for the league being crawled), and participation must count all of them —
  same scope `observed_picks.picked_by` already has, no FK either.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedDraft

  @primary_key false
  schema "draft_participants" do
    belongs_to :draft, ObservedDraft, references: :id
    field :user_id, :integer

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
