defmodule SleeperPlayerApi.Repo.Migrations.IndexHistoryForMovement do
  use Ecto.Migration

  def change do
    # The movement read — `DISTINCT ON (player_id) ... WHERE source = ?
    # AND day <= ? ORDER BY player_id, day DESC` — had no index it could walk
    # in order, and neither existing one fits:
    #
    #   * the unique `(player_id, source, day)` leads with `player_id`, so
    #     filtering by source scans the whole table
    #   * `(source, day)` filters well but leaves the rows unordered for the
    #     DISTINCT ON, forcing a sort
    #
    # Measured on production with 1.16M rows: a bitmap scan over 567,050 rows
    # followed by a disk-spilling sort, 727ms for the subquery alone. Cold,
    # the whole request exceeded the pool timeout and returned a 500 — the
    # endpoint's very first real call.
    #
    # This index is in exactly `DISTINCT ON` order, so Postgres walks it and
    # takes the first row per player rather than sorting anything.
    #
    # `day DESC` is explicit: the query wants the *most recent* close on or
    # before the target, and an ascending index would have it scanning to the
    # end of each player's run to find it.
    create index(:player_value_history, [:source, :player_id, "day DESC"],
             name: :player_value_history_movement_index
           )
  end
end
