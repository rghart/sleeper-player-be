defmodule SleeperPlayerApi.Sleeper.Team do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Sleeper.Player

  schema "teams" do
    field :abbreviation, :string
    has_many :players, Player

    timestamps()
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:abbreviation])
    |> validate_required([:abbreviation])
    |> unique_constraint(:abbreviation)
  end
end
