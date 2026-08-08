defmodule SleeperPlayerApi.Repo.Migrations.AddTransactionsFetchedThroughToObservedLeagues do
  use Ecto.Migration

  def change do
    # The highest week whose transactions are settled and will never change
    # again, so a nightly pass can skip it. Deliberately *not* "the last week
    # we fetched": the current week is still live and has to be refetched
    # every time, which in the offseason means week 1 forever — everything
    # lands there and it never closes.
    alter table(:observed_leagues) do
      add :transactions_fetched_through, :integer
    end
  end
end
