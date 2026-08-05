defmodule SleeperPlayerApi.Repo.Migrations.CreateSleeperUsers do
  use Ecto.Migration

  def change do
    create table(:sleeper_users, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :username, :string
      add :display_name, :string
      add :avatar, :string
      add :last_crawled_at, :utc_datetime

      timestamps()
    end
  end
end
