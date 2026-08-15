defmodule SleeperPlayerApi.Repo.Migrations.AddInjuryAndKtcExtras do
  use Ecto.Migration

  def change do
    # Injury comes from Sleeper's own nightly dump, not from KeepTradeCut.
    #
    # This was assumed the other way round until it was measured on
    # 2026-08-15. Sleeper's `/players/nfl` payload has carried
    # `injury_status` and `injury_body_part` all along — they sit unread
    # inside `players.player_json`, which the dump already stores. Across
    # active players: 357 Questionable, 73 IR, 61 NA, 55 PUP, 8 Sus, 5 Out,
    # 2 DNR, and 525 with a body part. On the 488-player dynasty pool that is
    # 77 with a status, against KTC's 75 — the same answer from a source the
    # app already fetches, refreshes nightly, and uses for every other player
    # fact.
    #
    # So no new request buys this, and it does not belong on `player_values`:
    # an injury is a fact about a player, not about what a market thinks he
    # is worth. `Player.changeset/2` casts from the raw payload, so adding
    # the columns to the cast list is all the nightly dump needs to fill them.
    alter table(:players) do
      add :injury_status, :string
      add :injury_body_part, :string
    end

    # What KeepTradeCut has that Sleeper does not.
    #
    # `liquidity` is KTC's `stdLiquidity`, 0-100 — how *tradeable* a player
    # is, as distinct from what he is worth. Measured live: present for all
    # 500 entries, range 0.0-99.0, mean 20.7. It is the one field here with no
    # sample-size caveat, and it says something a value cannot — "worth 4,300
    # but almost never moves" is a warning the number alone hides.
    #
    # Deliberately NOT `trade_frequency`, which stays null for KTC. Those are
    # different measurements from different providers and folding one into the
    # other would make two sources look comparable on a column where they are
    # not — the same reason `roster_percent` stays null. See the source's
    # moduledoc.
    #
    # `injury_return` is an expected return date. Sleeper carries nothing like
    # it: measured on the dynasty pool, 0 of 77 injured players have an
    # `injury_start_date` and only 21 have `injury_notes`, which is a one-word
    # cause ("Surgery", "Soreness") rather than a timeline. It is stored as a
    # date, not KTC's "Aug 22, 2026" string, so that a return already in the
    # past can be told from one still ahead — an unparseable value is dropped
    # rather than guessed at, the same rule `parse_pick/1` follows.
    #
    # `bye_week` likewise: Sleeper's player payload has no bye week at all
    # (0 of 488 on the pool), and KTC ships one for every entry.
    #
    # These two are per-*player* while `liquidity` is per-format, so both are
    # duplicated across the `keeptradecut:1qb` and `keeptradecut:sf` rows. The
    # alternative was a second writer into `players`, which the Sleeper dump
    # owns; two nullable columns repeated across two rows a player is a much
    # smaller price than splitting ownership of that table.
    alter table(:player_values) do
      add :liquidity, :float
      add :injury_return, :date
      add :bye_week, :integer
    end
  end
end
