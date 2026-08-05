defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedTradedPicks do
  use Ecto.Migration

  def change do
    create table(:observed_traded_picks, primary_key: false) do
      add :draft_id,
          references(:observed_drafts, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      add :season, :string
      add :round, :integer
      add :roster_id, :integer
      add :previous_owner_id, :integer
      add :owner_id, :integer

      timestamps()
    end

    create unique_index(:observed_traded_picks, [:draft_id, :season, :round, :roster_id])
    create index(:observed_traded_picks, [:draft_id])
  end
end
