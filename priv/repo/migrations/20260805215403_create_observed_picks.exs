defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedPicks do
  use Ecto.Migration

  def change do
    create table(:observed_picks, primary_key: false) do
      add :draft_id,
          references(:observed_drafts, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      add :pick_no, :integer, null: false
      add :round, :integer
      add :draft_slot, :integer
      add :roster_id, :integer
      add :player_id, :string
      add :picked_by, :bigint

      timestamps()
    end

    create unique_index(:observed_picks, [:draft_id, :pick_no])
    create index(:observed_picks, [:player_id])
    create index(:observed_picks, [:picked_by])
  end
end
