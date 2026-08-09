defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedRosters do
  use Ecto.Migration

  def change do
    # One row per roster per league: who owns it, and who is on it right now.
    #
    # `observed_leagues.roster_to_user` already answers "who owns roster N",
    # which is why the transactions crawler fetches `/league/:id/rosters` once
    # and never again. This table is the part of that same payload it throws
    # away — `players` — and it is *not* stable within a season: it changes
    # with every trade, waiver and free-agent add.
    #
    # Measured 2026-08-09, this is what makes a per-manager ownership read
    # possible: 94% of (manager, player) ownership pairs are invisible to the
    # rookie-draft corpus, because they arrived by trade or waiver or in a
    # league whose draft was never crawled. It also gives the thin-sample
    # managers a denominator — `skeefe` has 1 corpus draft and 30 leagues.
    #
    # `player_ids` is text[], not a jsonb map: Sleeper player ids are strings
    # in the payload and the only query is membership.
    create table(:observed_rosters, primary_key: false) do
      add :league_id, references(:observed_leagues, on_delete: :delete_all, type: :bigint),
        null: false

      add :roster_id, :integer, null: false
      add :owner_id, :bigint
      add :player_ids, {:array, :text}, null: false, default: []
      add :fetched_at, :utc_datetime

      timestamps()
    end

    create unique_index(:observed_rosters, [:league_id, :roster_id])
    # The read is "which of this manager's rosters hold player X", so the
    # owner is the selective side.
    create index(:observed_rosters, [:owner_id])
  end
end
