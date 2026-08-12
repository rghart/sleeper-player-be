defmodule SleeperPlayerApi.Repo.Migrations.CreatePlayerValueHistory do
  use Ecto.Migration

  def change do
    # The time series `player_values` cannot be, because that table is keyed
    # `(player_id, source)` and refreshed in place — every nightly run since
    # 2026-08-05 overwrote the previous day's numbers and kept nothing. Price
    # *movement* is the whole of the in-season dynasty read (buy-low and
    # sell-high are both statements about a value changing), so the raw
    # material for it was being collected and discarded in the same job.
    #
    # One row per player per source per day, holding that day's close: the
    # last observation written on that date wins, via the same
    # `on_conflict: replace` path every other upsert here uses.
    #
    # **Daily, deliberately, not per-fetch.** Measured 2026-08-12 against the
    # live KTC payload: 7 of 500 values changed between two fetches roughly
    # two minutes apart. Values move continuously, so "append only when
    # changed" at an hourly cadence lands near the worst case (~3.5M rows and
    # ~600MB-900MB a year) rather than near the floor. Daily is ~365k rows and
    # ~55MB a year across every source and variant, and loses nothing the
    # queries want — the question is always "how far has he moved in three
    # weeks", never "where was he at 3pm".
    #
    # At that size no retention job is needed, and building one now would be
    # complexity for nothing. `day` is a date column precisely so that if
    # intraday retention is ever added it goes in its own short-lived table,
    # and downsampling this one to weekly stays a single windowed DELETE.
    create table(:player_value_history, primary_key: false) do
      add :player_id, :bigint, null: false
      add :source, :string, null: false

      # UTC date of `as_of`. A single fixed boundary matters more than which
      # one it is — the crawl runs at 4:30am Central and an hourly KTC refresh
      # runs on the hour, so the only requirement is that both agree on which
      # day a write belongs to.
      add :day, :date, null: false

      # Only the movement fields. `roster_percent` and `trade_frequency` live
      # on `player_values` and are deliberately not carried here: they are
      # provider-specific, slow-moving, and not what a time series of *price*
      # is for. Adding a column later is a cheap migration; carrying dead
      # weight in every row of a time series is not.
      add :value, :float
      add :overall_rank, :integer
      add :position_rank, :integer

      # The exact observation behind the close, kept alongside `day` so a row
      # can say when it was actually taken rather than only which day it
      # belongs to.
      add :as_of, :utc_datetime

      timestamps()
    end

    # Also serves the trajectory read ("this player, this source, over time"),
    # since its leading columns are exactly that query's filter — no separate
    # index for it.
    create unique_index(:player_value_history, [:player_id, :source, :day])

    # The other direction: "who moved" across the whole board on a given day,
    # which is the feed query rather than the player query.
    create index(:player_value_history, [:source, :day])
  end
end
