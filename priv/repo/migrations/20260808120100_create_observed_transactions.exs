defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedTransactions do
  use Ecto.Migration

  def change do
    create table(:observed_transactions, primary_key: false) do
      # Sleeper's own transaction_id, so a refetch of a live week upserts
      # rather than duplicating. That matters more here than for picks: in the
      # offseason every transaction lands in week 1 and week 1 stays live, so
      # the same rows are re-fetched nightly for months.
      add :id, :bigint, primary_key: true

      add :league_id,
          references(:observed_leagues, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      add :week, :integer, null: false
      add :type, :string
      add :status, :string
      add :created, :utc_datetime
      add :creator, :bigint

      # Resolved through `observed_leagues.roster_to_user` at write time.
      # Filtering on `creator` alone silently drops every trade a manager
      # accepted rather than proposed — and trades are the rarest and most
      # interesting type, so that undercount would be invisible and wrong.
      add :participant_ids, {:array, :bigint}, default: [], null: false

      # `%{player_id => roster_id}` as Sleeper sends them.
      add :adds, :map
      add :drops, :map
      # Pick trades arrive free in the same payload.
      add :draft_picks, {:array, :map}, default: [], null: false
      add :waiver_bid, :integer

      timestamps()
    end

    create index(:observed_transactions, [:league_id, :week])
    create index(:observed_transactions, [:creator])
    create index(:observed_transactions, [:created])
    # A manager's activity is read by "was I involved", not "did I create it".
    create index(:observed_transactions, [:participant_ids], using: :gin)
  end
end
