defmodule SleeperPlayerApi.Repo.Migrations.CreatePlayerProjections do
  use Ecto.Migration

  # Sleeper's season-long projections, one row per player per season, for
  # the power rankings' projection and ADP sources (docs/dynasty-engine.md,
  # M1 step 3). `stats` is Sleeper's raw stat map rather than any one score,
  # because each league scores it against its own `scoring_settings`: a
  # TE-premium league and a six-point-passing league read the same row
  # differently. About 3,300 rows a season.
  def change do
    create table(:player_projections, primary_key: false) do
      add :season, :integer, null: false
      add :player_id, :string, null: false
      add :stats, :map, null: false, default: %{}

      # Sleeper's own `last_modified` for the row, so a response can say how
      # old the projection is rather than when this app happened to fetch it.
      add :projected_at, :utc_datetime

      timestamps()
    end

    create unique_index(:player_projections, [:season, :player_id])
  end
end
