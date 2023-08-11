defmodule SleeperPlayerApi.Repo.Migrations.CreateStatuses do
  use Ecto.Migration

  def change do
    create table(:statuses) do
      add :status, :string, null: false

      timestamps()
    end

    create unique_index(:statuses, [:status])
  end
end
