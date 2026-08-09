defmodule SleeperPlayerApi.Intel.LeagueMember do
  @moduledoc """
  A tracked leaguemate's membership of one league.

  The crawl learns this while enumerating each user's leagues and used to
  discard it in the dedupe. It is kept because coverage needs an honest
  denominator: "33 of 42 of their leagues" is a claim about them, where
  "33 of 175" — every league in the corpus — is a claim about nothing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedLeague

  @primary_key false
  schema "league_members" do
    belongs_to :league, ObservedLeague, references: :id, type: :id, define_field: false
    field :league_id, :integer
    field :user_id, :integer

    timestamps()
  end

  @doc false
  def changeset(league_member, attrs) do
    league_member
    |> cast(attrs, [:league_id, :user_id])
    |> validate_required([:league_id, :user_id])
    |> unique_constraint([:league_id, :user_id])
  end
end
