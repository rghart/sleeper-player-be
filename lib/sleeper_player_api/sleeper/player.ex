defmodule SleeperPlayerApi.Sleeper.Player do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Sleeper.{Team, Position, Status, FantasyPositions}

  @primary_key {:id, :id, autogenerate: false}
  schema "players" do
    field :active, :boolean, default: false
    field :player_json, :string
    field :age, :integer
    field :first_name, :string
    field :last_name, :string
    field :full_name, :string
    field :player_id, :string
    field :search_first_name, :string
    field :search_last_name, :string
    field :search_full_name, :string
    field :search_rank, :integer
    field :years_exp, :integer

    belongs_to :team, Team, on_replace: :update
    belongs_to :position, Position, on_replace: :update
    belongs_to :status, Status, on_replace: :update
    many_to_many :fantasy_positions, Position, join_through: FantasyPositions, on_replace: :delete

    timestamps()
  end

  @doc false
  def changeset(player, attrs) do
    player
    |> cast(attrs, [:id, :player_json, :active, :age, :first_name, :last_name, :full_name, :player_id, :search_first_name, :search_last_name, :search_full_name, :search_rank, :years_exp, :position_id, :status_id, :team_id])
    |> validate_required([:player_json, :active, :first_name, :last_name, :full_name, :player_id, :search_first_name, :search_last_name, :search_full_name])
    |> unique_constraint([:player_id])
  end
end
