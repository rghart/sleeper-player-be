defmodule SleeperPlayerApi.Repo.Migrations.CreateFantasyPositions do
  use Ecto.Migration

  def change do
    create table(:fantasy_positions, primary_key: false) do
      add :player_id, references(:players, on_delete: :delete_all), null: false
      add :position_id, references(:positions, on_delete: :delete_all), null: false
    end

    create index(:fantasy_positions, [:player_id])
    create index(:fantasy_positions, [:position_id])
    create unique_index(:fantasy_positions, [:player_id, :position_id])
  end
end
