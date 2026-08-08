defmodule SleeperPlayerApi.Repo.Migrations.CreateLeagueMembers do
  use Ecto.Migration

  def change do
    # Which leaguemates are in which leagues. The crawl already learns this
    # while enumerating (`/user/:id/leagues`) and used to throw it away in the
    # dedupe.
    #
    # It exists because coverage needs an honest denominator. Without it,
    # `transaction_coverage/2` compared a manager's leagues-with-activity
    # against *every* league in the corpus — so a real run reported
    # "33/175 leagues" for a manager who is in 42. Found by running the
    # crawler against the live API; no test noticed, because every fixture
    # had one league.
    create table(:league_members, primary_key: false) do
      add :league_id,
          references(:observed_leagues, column: :id, type: :bigint, on_delete: :delete_all),
          null: false

      add :user_id, :bigint, null: false

      timestamps()
    end

    create unique_index(:league_members, [:league_id, :user_id])
    create index(:league_members, [:user_id])
  end
end
