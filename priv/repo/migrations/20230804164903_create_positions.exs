defmodule SleeperPlayerApi.Repo.Migrations.CreatePositions do
  use Ecto.Migration

  def change do
    create table(:positions) do
      add :abbreviation, :string, null: false

      timestamps()
    end

    create unique_index(:positions, [:abbreviation])
  end
end
