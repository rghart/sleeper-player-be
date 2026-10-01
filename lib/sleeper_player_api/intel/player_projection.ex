defmodule SleeperPlayerApi.Intel.PlayerProjection do
  @moduledoc """
  One player's season-long projection from Sleeper, as stored by
  `SleeperPlayerApi.Tasks.RefreshProjections`. See the migration for why the
  raw stat map is kept rather than a score.
  """

  use Ecto.Schema

  @primary_key false
  schema "player_projections" do
    field :season, :integer
    field :player_id, :string
    field :stats, :map
    field :projected_at, :utc_datetime

    timestamps()
  end
end
