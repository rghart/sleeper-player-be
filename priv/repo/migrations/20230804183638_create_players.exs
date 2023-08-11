defmodule SleeperPlayerApi.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :player_json, :text, null: false
      add :active, :boolean, default: false, null: false
      add :age, :integer
      add :first_name, :string, null: false
      add :last_name, :string, null: false
      add :full_name, :string, null: false
      add :player_id, :string, null: false
      add :search_first_name, :string, null: false
      add :search_last_name, :string, null: false
      add :search_full_name, :string, null: false
      add :search_rank, :integer
      add :years_exp, :integer
      add :position_id, references(:positions, on_delete: :nothing)
      add :status_id, references(:statuses, on_delete: :nothing)
      add :team_id, references(:teams, on_delete: :nothing)

      timestamps()
    end

    create unique_index(:players, [:player_id])
    create index(:players, [:position_id])
    create index(:players, [:status_id])
    create index(:players, [:team_id])
  end
end
