defmodule SleeperPlayerApi.Repo.Migrations.CreateObservedRosterHistory do
  use Ecto.Migration

  def change do
    # The time series `observed_rosters` cannot be. That table is keyed
    # `(league_id, roster_id)` and refreshed in place on every crawl, so it
    # holds exactly one current snapshot and has kept nothing since it was
    # created on 2026-08-09 — the same shape `player_values` was in before
    # `player_value_history`, and the same fix.
    #
    # **Why it matters, and why the clock is the point.** Positional need
    # cannot be *validated* against current rosters: measured 2026-08-09, 99%
    # of players taken in corpus drafts are still rostered now, so today's
    # rosters contain the answer to "was this manager thin at RB when he drew
    # that pick". Only a roster as it stood *then* can say. Nothing here pays
    # off until a season's worth has accumulated, which is exactly why the
    # table has to exist before the season rather than when the question is
    # asked. Rendering need as live *context* is unaffected and already works.
    #
    # One row per roster per day, holding that day's close — the last
    # observation written on a date wins, via the same `on_conflict: replace`
    # path every other upsert here uses. The crawl is nightly, so daily is
    # per-crawl today; stating it as a day means a second run overwrites
    # rather than duplicating.
    #
    # **Daily-always, not append-on-change.** Measured 2026-08-15 against
    # production: 2,238 rosters across 179 leagues, 26.4 players each,
    # `observed_rosters` totalling 1,616 kB — so ~740 bytes a row and about
    # **605 MB a year** written unconditionally, against a 305 MB database and
    # 14 GB free. Skipping unchanged rosters would cut that roughly fourfold
    # (rosters move weekly in season, barely at all outside it), and was
    # rejected anyway: it makes a missing day ambiguous between "nothing
    # changed" and "we never looked", and every query here is a point-in-time
    # read of the form "latest snapshot on or before day D", which is only
    # sound when absence means unobserved. A failed roster fetch already
    # writes nothing, so that reading holds. Buying crisp semantics for
    # ~470 MB a year is the right trade at this size; if it ever stops being,
    # downsampling to weekly is a single windowed DELETE, which is the same
    # escape hatch `player_value_history` left itself.
    create table(:observed_roster_history, primary_key: false) do
      add :league_id, references(:observed_leagues, on_delete: :delete_all, type: :bigint),
        null: false

      add :roster_id, :integer, null: false

      # UTC date of `fetched_at`, never `Date.utc_today()` — a row must land
      # on the day it describes so that a backfill, or a crawl that straddles
      # midnight, is filed correctly rather than filed as today.
      add :day, :date, null: false

      # Carried rather than joined to `observed_rosters`: ownership changes
      # when a league replaces a manager mid-season, and a snapshot that has
      # to be joined to a mutable table to be read is not a snapshot.
      add :owner_id, :bigint
      add :player_ids, {:array, :text}, null: false, default: []
      add :fetched_at, :utc_datetime

      timestamps()
    end

    # Serves the upsert, the per-roster time series, and the per-league
    # point-in-time read ("every roster in league L on day D"), since its
    # leading columns are exactly those filters.
    #
    # No `owner_id` index yet, deliberately. The owner-side read is the one
    # `observed_rosters` indexes, but nothing queries this table by owner
    # today, and an index costs every insert of ~2,238 rows every night
    # forever. Adding one when a query needs it is a cheap migration.
    create unique_index(:observed_roster_history, [:league_id, :roster_id, :day])
  end
end
