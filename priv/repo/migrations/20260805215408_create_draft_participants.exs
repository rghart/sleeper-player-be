defmodule SleeperPlayerApi.Repo.Migrations.CreateDraftParticipants do
  use Ecto.Migration

  def change do
    create table(:draft_participants, primary_key: false) do
      add :draft_id,
          references(:observed_drafts, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:sleeper_users, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create unique_index(:draft_participants, [:draft_id, :user_id])
    create index(:draft_participants, [:user_id])
  end
end
