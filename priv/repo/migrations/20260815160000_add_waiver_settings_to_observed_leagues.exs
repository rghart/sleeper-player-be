defmodule SleeperPlayerApi.Repo.Migrations.AddWaiverSettingsToObservedLeagues do
  use Ecto.Migration

  def change do
    # Both already arrive in a payload the crawler reads and throws away:
    # `/user/:id/leagues/nfl/:season` returns whole league objects, and
    # `enumerate_leagues/3` keeps `league_id` and `name` out of them. So this
    # costs no request, exactly like the injury fields did.
    #
    # **Without `waiver_budget` a bid is not a number you can compare.**
    # Measured 2026-08-15 over 40 corpus leagues that actually carry bids:
    # budget 100 on 17 of them, 200 on 8, 1000 on 8, 150 on 4, 300 on 2, 250
    # on 1. Only about 42% use the standard hundred, so a bid of 50 is half a
    # budget in one league and a twentieth in another, and averaging the raw
    # figures across leagues produces a number about nothing. Every bid this
    # app reports has to be a share of its own league's budget.
    #
    # **Without `waiver_type` a zero is ambiguous.** Sleeper stores
    # `waiver_bid` on every transaction, so a league on rolling waivers or
    # standard priority (types 0 and 1) contributes zeros that are not bids of
    # nothing — they are the absence of bidding. Type 2 is FAAB. Pooling the
    # rest would drag every average toward zero while looking like data; 2,784
    # of the 4,945 non-null bids in the corpus are zeros, and how many of those
    # are real free claims cannot be told apart until this column exists.
    alter table(:observed_leagues) do
      add :waiver_budget, :integer
      add :waiver_type, :integer
    end
  end
end
