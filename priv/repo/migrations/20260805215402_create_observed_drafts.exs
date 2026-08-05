defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedDrafts do
  use Ecto.Migration

  def change do
    create table(:observed_drafts, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :league_id, :bigint
      add :season, :string
      add :status, :string
      add :draft_type, :string
      add :player_type, :integer
      add :teams, :integer
      add :rounds, :integer
      add :start_time, :bigint
      add :slot_to_roster_id, :map
      add :picks_fetched_at, :utc_datetime

      timestamps()
    end

    create index(:observed_drafts, [:league_id])
    create index(:observed_drafts, [:status])
    create index(:observed_drafts, [:season])
  end
end
