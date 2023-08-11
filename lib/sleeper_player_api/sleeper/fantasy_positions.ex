defmodule SleeperPlayerApi.Sleeper.FantasyPositions do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Sleeper.Player
  alias SleeperPlayerApi.Sleeper.Position

  @primary_key false
  schema "fantasy_positions" do
    belongs_to :player, Player
    belongs_to :position, Position
  end

  @doc false
  def changeset(fantasy_positions, attrs) do
    fantasy_positions
    |> cast(attrs, [:player_id, :position_id])
    |> validate_required([:player_id, :position_id])
    |> unique_constraint([:player_id, :position_id])
  end
end
