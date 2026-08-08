defmodule SleeperPlayerApi.Intel.TransactionsTest do
  @moduledoc """
  Phase 1 of plan §6 step 6: schema and context, no HTTP.

  Everything here goes through the real `Intel` functions the crawler will
  call, seeded from plain maps in the shape `/league/:id/transactions/:week`
  actually returns — verified against the live endpoint on 2026-08-08, so the
  payload shapes below are copied from real responses rather than imagined.
  """
  use SleeperPlayerApi.DataCase, async: true

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.ObservedTransaction
  alias SleeperPlayerApi.Repo

  @league 1_313_425_233_297_813_504
  @baconstains 207_584_750_204_878_848
  @atekipp 859_581_197_427_257_344
  @getforked 815_346_571_532_161_024

  # `roster_to_user` round-trips as jsonb, so roster ids are string keys.
  @roster_map %{"9" => @getforked, "10" => @baconstains, "8" => @atekipp}

  defp seed_league(attrs \\ %{}) do
    Intel.upsert_observed_leagues([
      Map.merge(
        %{
          id: @league,
          name: "District 13 Dynasty League",
          season: "2026",
          roster_to_user: @roster_map,
          rosters_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    ])
  end

  defp transaction(id, attrs) do
    Map.merge(
      %{
        id: id,
        league_id: @league,
        week: 1,
        type: "free_agent",
        status: "complete",
        created: DateTime.utc_now() |> DateTime.truncate(:second),
        creator: @baconstains,
        participant_ids: [@baconstains],
        adds: %{},
        drops: %{},
        draft_picks: [],
        waiver_bid: nil
      },
      attrs
    )
  end

  describe "participants/2 — the reason observed_leagues exists" do
    test "resolves roster ids to the users behind them, creator included" do
      # A real trade payload: `creator` is a USER id, `roster_ids` are ROSTER
      # ids. Attributing only to the creator would drop baconstains entirely,
      # and he is half the trade.
      raw = %{"creator" => to_string(@getforked), "roster_ids" => [9, 10]}

      assert Intel.participants(raw, @roster_map) == Enum.sort([@getforked, @baconstains])
    end

    test "keeps the creator even when the roster map cannot place them" do
      # A league whose rosters have not been fetched yet still yields partial
      # attribution rather than none.
      raw = %{"creator" => to_string(@baconstains), "roster_ids" => [3, 4]}

      assert Intel.participants(raw, %{}) == [@baconstains]
    end

    test "does not duplicate a creator who is also on a roster" do
      raw = %{"creator" => to_string(@baconstains), "roster_ids" => [10]}

      assert Intel.participants(raw, @roster_map) == [@baconstains]
    end

    test "survives a free agent add, which has one roster and no counterparty" do
      raw = %{"creator" => to_string(@atekipp), "roster_ids" => [8]}

      assert Intel.participants(raw, @roster_map) == [@atekipp]
    end
  end

  describe "upserts" do
    test "a transaction is keyed on Sleeper's own id, so refetching a live week updates rather than duplicates" do
      # This is not hypothetical: in the offseason every transaction lands in
      # week 1 and week 1 never closes, so the same rows come back nightly.
      seed_league()
      Intel.upsert_observed_transactions([transaction(1, %{status: "pending"})])
      Intel.upsert_observed_transactions([transaction(1, %{status: "complete"})])

      assert [row] = Repo.all(ObservedTransaction)
      assert row.status == "complete"
    end

    test "a league upsert does not blank a roster map an earlier pass stored" do
      # The crawl fetches transactions nightly but rosters rarely. A nightly
      # pass that touches the league row without a roster map must not wipe
      # the one already there, or trade attribution silently degrades.
      seed_league()
      Intel.upsert_observed_leagues([%{id: @league, name: "District 13 Dynasty League"}])

      league = Repo.get(SleeperPlayerApi.Intel.ObservedLeague, @league)
      assert league.roster_to_user == %{"9" => @getforked, "10" => @baconstains, "8" => @atekipp}
      assert league.rosters_fetched_at != nil
    end
  end

  describe "transactions_for_user/2" do
    setup do
      seed_league()

      Intel.upsert_observed_transactions([
        transaction(1, %{
          type: "trade",
          creator: @getforked,
          participant_ids: Enum.sort([@getforked, @baconstains]),
          created: ~U[2026-08-01 12:00:00Z]
        }),
        transaction(2, %{
          type: "waiver",
          creator: @baconstains,
          participant_ids: [@baconstains],
          created: ~U[2026-08-05 12:00:00Z]
        }),
        transaction(3, %{
          type: "free_agent",
          creator: @atekipp,
          participant_ids: [@atekipp],
          created: ~U[2026-08-06 12:00:00Z]
        }),
        transaction(4, %{
          type: "waiver",
          status: "failed",
          creator: @baconstains,
          participant_ids: [@baconstains],
          created: ~U[2026-08-07 12:00:00Z]
        })
      ])

      :ok
    end

    test "finds a trade the user accepted rather than created" do
      # The whole point of participant_ids. baconstains created nothing in
      # transaction 1 — getforked did — and he is still half of it.
      ids = @baconstains |> Intel.transactions_for_user() |> Enum.map(& &1.id)

      assert 1 in ids
    end

    test "does not return other managers' activity" do
      ids = @atekipp |> Intel.transactions_for_user() |> Enum.map(& &1.id)

      assert ids == [3]
    end

    test "returns newest first" do
      ids = @baconstains |> Intel.transactions_for_user() |> Enum.map(& &1.id)

      assert ids == [4, 2, 1]
    end

    test "keeps failed transactions, because a failed claim is a revealed preference" do
      # Nobody else in that league can see it. Filtering happens at display,
      # with a label — not at ingest, and not here.
      rows = Intel.transactions_for_user(@baconstains)

      assert Enum.any?(rows, &(&1.status == "failed"))
    end

    test "narrows by type when asked" do
      ids = @baconstains |> Intel.transactions_for_user(types: ["trade"]) |> Enum.map(& &1.id)

      assert ids == [1]
    end

    test "caps at the limit, newest first" do
      assert [%{id: 4}] = Intel.transactions_for_user(@baconstains, limit: 1)
    end

    test "scopes to a season through the league" do
      assert @baconstains |> Intel.transactions_for_user(season: "2026") |> length() == 3
      assert Intel.transactions_for_user(@baconstains, season: "2025") == []
    end
  end

  describe "transaction_coverage/2" do
    test "reports leagues seen against leagues known, so a partial answer can say so" do
      # A fan-out that saw 1 of 2 leagues and reported "3 transactions" would
      # be a figure without its sample size — the error this feature keeps
      # re-learning.
      seed_league()
      Intel.upsert_observed_leagues([%{id: 999, name: "Another", season: "2026"}])
      Intel.upsert_observed_transactions([transaction(1, %{})])

      coverage = Intel.transaction_coverage(@baconstains, season: "2026")

      assert coverage.leagues_seen == 1
      assert coverage.leagues_known == 2
      assert coverage.last_crawled_at != nil
    end

    test "is zeroes rather than nils for a user with nothing stored" do
      seed_league()

      assert %{leagues_seen: 0, leagues_known: 1} = Intel.transaction_coverage(@atekipp)
    end
  end
end
