defmodule SleeperPlayerApi.Intel.PlayerValue do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "player_values" do
    field :player_id, :integer
    field :source, :string
    field :value, :float
    field :overall_rank, :integer
    field :position_rank, :integer
    field :roster_percent, :float
    field :trade_frequency, :float
    field :as_of, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(player_value, attrs) do
    player_value
    |> cast(attrs, [
      :player_id,
      :source,
      :value,
      :overall_rank,
      :position_rank,
      :roster_percent,
      :trade_frequency,
      :as_of
    ])
    |> validate_required([:player_id, :source])
    |> unique_constraint([:player_id, :source])
  end
end
