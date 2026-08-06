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
    # Season the player was drafted in (FantasyCalc's `maybeDraftInfo.year`).
    # `nil` for a veteran or anyone the feed carries no draft info for — see
    # the migration that added this column. Feeds the rookie-class filter
    # (plan §3f step 5 / estimator §8), which is "rank within the ROOKIE
    # CLASS", not the full player pool.
    field :draft_year, :integer

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
      :as_of,
      :draft_year
    ])
    |> validate_required([:player_id, :source])
    |> unique_constraint([:player_id, :source])
  end
end
