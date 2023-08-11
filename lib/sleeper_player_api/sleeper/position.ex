defmodule SleeperPlayerApi.Sleeper.Position do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Sleeper.Player
  alias SleeperPlayerApi.Sleeper.FantasyPositions

  @derive {Jason.Encoder, only: [:abbreviation]}
  schema "positions" do
    field :abbreviation, :string
    has_many :players, Player
    many_to_many :fantasy_players, Player, join_through: FantasyPositions

    timestamps()
  end

  @doc false
  def changeset(position, attrs) do
    position
    |> cast(attrs, [:abbreviation])
    |> validate_required([:abbreviation])
    |> unique_constraint(:abbreviation)
  end
end
