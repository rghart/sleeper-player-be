defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedLeagues do
  use Ecto.Migration

  def change do
    # Keyed on Sleeper's own league id, same convention as `observed_drafts`.
    #
    # `roster_to_user` is the reason this table exists. A transaction payload
    # gives `creator` as a *user* id but `consenter_ids`/`roster_ids` as
    # *roster* ids, so attributing a trade to the manager who accepted it
    # needs this map — and without somewhere to keep it, every crawl would
    # re-fetch `/league/:id/rosters` for all 176 leagues. Which user owns
    # roster N effectively never changes within a season.
    create table(:observed_leagues, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string
      add :season, :string
      add :roster_to_user, :map
      add :rosters_fetched_at, :utc_datetime

      timestamps()
    end

    create index(:observed_leagues, [:season])
  end
end
