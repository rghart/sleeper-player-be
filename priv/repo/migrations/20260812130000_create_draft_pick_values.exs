defmodule SleeperPlayerApi.Repo.Migrations.CreateDraftPickValues do
  use Ecto.Migration

  def change do
    # What a rookie draft pick is worth, which nothing in this codebase has
    # ever been able to say.
    #
    # The app tracks traded picks end to end (`observed_traded_picks`, and the
    # frontend's own traded-pick resolution), and every one of them has been
    # priceless in the unhelpful sense. FantasyCalc does not price picks;
    # KeepTradeCut does, as 36 entries in the same payload as the players —
    # 3 seasons x 3 tiers x 4 rounds, exactly regular.
    #
    # They cannot live in `player_values`: that table is keyed by a Sleeper
    # *player* id and a pick is not a player. KTC marks them with `mflid: 0`
    # and the value source drops them, which is what this table is for.
    #
    # **`tier` is the modelling problem, and it is not solvable here.** KTC
    # prices "2027 Early 1st" separately from "2027 Late 1st", but a Sleeper
    # traded pick carries only season and round — which tier it becomes
    # depends on where that roster finishes, which is not known until it does.
    # So all three tiers are stored and the *caller* chooses: mid is the
    # honest default for an unknown pick, and a caller who knows the standings
    # can do better. Collapsing to one number here would bake a guess into
    # storage where nothing downstream could see it.
    create table(:draft_pick_values, primary_key: false) do
      add :season, :integer, null: false
      add :round, :integer, null: false
      add :tier, :string, null: false
      add :source, :string, null: false

      add :value, :float
      add :overall_rank, :integer
      add :position_rank, :integer
      add :as_of, :utc_datetime

      timestamps()
    end

    create unique_index(:draft_pick_values, [:season, :round, :tier, :source])

    # The read is "price these picks for my league's variant", so the source
    # is the selective side and season/round follow.
    create index(:draft_pick_values, [:source, :season, :round])
  end
end
