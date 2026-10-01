defmodule SleeperPlayerApi.Repo.Migrations.CreateMarketCorpus do
  use Ecto.Migration

  # The market draft corpus for ADP from real drafts (docs/dynasty-engine.md,
  # M3). Deliberately separate from `observed_drafts`/`observed_picks`: those
  # are leaguemate intel, read by the availability model that is calibrated
  # against them, and every reader assumes a rookie draft by a leaguemate.
  # This corpus holds strangers' drafts, startups as well as rookie drafts,
  # each with its format, so mixing the two would change a calibrated model
  # by accident.
  def change do
    # The crawl frontier: Sleeper users whose drafts to read, found by
    # snowballing outward from the leaguemate corpus. `depth` is how many
    # leagues removed from a seed a user was found.
    create table(:market_users, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :depth, :integer, null: false, default: 0
      add :crawled_at, :utc_datetime

      timestamps()
    end

    create index(:market_users, [:crawled_at])

    # A league seen while crawling: its format (only the league object knows
    # the TE premium) and whether its users have been added to the frontier.
    create table(:market_leagues, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :season, :string
      add :league_type, :integer
      add :te_premium, :float
      add :ppr, :float
      add :total_rosters, :integer
      add :users_crawled_at, :utc_datetime

      timestamps()
    end

    # One completed dynasty draft, with the format its ADP belongs to.
    # `qb_slots` is QB slots plus superflex: how many quarterbacks a lineup
    # can start, which is what splits 1QB from superflex drafting.
    # `complete` is the quality bar - every pick made, each with a player.
    create table(:market_drafts, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :league_id, :bigint
      add :season, :string
      add :kind, :string, null: false
      add :draft_type, :string
      add :teams, :integer
      add :rounds, :integer
      add :qb_slots, :integer
      add :te_premium, :float
      add :ppr, :float
      add :scoring_type, :string
      add :started_at, :utc_datetime
      add :picks_count, :integer
      add :complete, :boolean, null: false, default: false

      timestamps()
    end

    create index(:market_drafts, [:kind, :started_at])

    create table(:market_picks, primary_key: false) do
      add :draft_id, references(:market_drafts, type: :bigint, on_delete: :delete_all),
        null: false

      add :pick_no, :integer, null: false
      add :round, :integer
      add :player_id, :string, null: false
    end

    create unique_index(:market_picks, [:draft_id, :pick_no])
    create index(:market_picks, [:player_id])
  end
end
