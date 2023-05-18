defmodule SleeperPlayerApi.Sleeper.Player do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "players" do
    field :active, :boolean, default: false
    field :age, :integer
    field :fantasy_positions, {:array, :string}
    field :first_name, :string
    field :full_name, :string
    field :last_name, :string
    field :player_id, :string
    field :player_json, :string
    field :position, :string
    field :search_first_name, :string
    field :search_full_name, :string
    field :search_last_name, :string
    field :search_rank, :integer
    field :status, :string
    field :team, :string
    field :years_exp, :integer

    timestamps()
  end

  @doc false
  def changeset(player, attrs) do
    player
    |> cast(attrs, [:player_json, :active, :age, :fantasy_positions, :first_name, :last_name, :full_name, :player_id, :position, :search_first_name, :search_last_name, :search_full_name, :search_rank, :status, :years_exp, :team])
    |> validate_required([:player_id])
    |> unique_constraint(:player_id)
  end
end
