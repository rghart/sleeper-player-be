defmodule SleeperPlayerApi.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :player_json, :map
      add :active, :boolean, default: false, null: false
      add :age, :integer
      add :fantasy_positions, {:array, :string}
      add :first_name, :string
      add :last_name, :string
      add :full_name, :string
      add :player_id, :string
      add :position, :string
      add :search_first_name, :string
      add :search_last_name, :string
      add :search_full_name, :string
      add :search_rank, :integer
      add :status, :string
      add :years_exp, :integer
      add :team, :string

      timestamps()
    end

    create unique_index(:players, [:player_id])
  end
end
