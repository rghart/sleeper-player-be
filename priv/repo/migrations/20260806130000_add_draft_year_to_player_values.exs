defmodule SleeperPlayerApi.Repo.Migrations.AddDraftYearToPlayerValues do
  use Ecto.Migration

  # Adds `draft_year` to `player_values` — plan §3f step 5's rookie-class
  # filter (estimator §8: "rank within the ROOKIE CLASS by FantasyCalc
  # `value`") needs to know which season a player was drafted in, and the
  # originally migrated `player_values` columns (§3a) don't carry it.
  #
  # Sourced from FantasyCalc's `player.maybeDraftInfo.year`, which is `nil`
  # for players the feed doesn't have draft info for at all (three of the
  # fixture's targets — Justin Joly, Michael Trigg, J'Mari Taylor — verified
  # in docs/leaguemate-intel-estimator.md §10 note 4). Nullable, no default:
  # a row with no draft year simply never matches a rookie-class filter,
  # which is correct for a veteran or an unclassified player.
  def change do
    alter table(:player_values) do
      add :draft_year, :integer
    end

    create index(:player_values, [:source, :draft_year])
  end
end
