defmodule SleeperPlayerApi.Repo.Migrations.CreatePlayerValues do
  use Ecto.Migration

  def change do
    create table(:player_values, primary_key: false) do
      add :player_id, :bigint, null: false
      add :source, :string, null: false
      add :value, :float
      add :overall_rank, :integer
      add :position_rank, :integer
      add :roster_percent, :float
      add :trade_frequency, :float
      add :as_of, :utc_datetime

      timestamps()
    end

    create unique_index(:player_values, [:player_id, :source])
    create index(:player_values, [:source])
  end
end
