defmodule SleeperPlayerApi.Intel.PickHoldingsTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.PickHoldings

  @priced [2026, 2027, 2028]

  describe "tradeable_seasons/2" do
    test "excludes a season whose draft this league has already run" do
      # The trap this module exists for. KeepTradeCut goes on pricing
      # "2026 Early 1st" after the 2026 rookie drafts are done, because its
      # list is about a market. District 13's 2026 draft is complete, so a
      # 2026 pick there is spent — and offering one would look plausible.
      drafts = [%{"season" => "2026", "status" => "complete"}]

      assert PickHoldings.tradeable_seasons(drafts, @priced) == [2027, 2028]
    end

    test "keeps a season whose draft has not finished" do
      drafts = [
        %{"season" => "2026", "status" => "complete"},
        %{"season" => "2027", "status" => "pre_draft"}
      ]

      assert PickHoldings.tradeable_seasons(drafts, @priced) == [2027, 2028]
    end

    test "never offers a season nobody prices" do
      # A pick with no value cannot close a value gap, which is the only job
      # a pick has here.
      assert PickHoldings.tradeable_seasons([], [2027]) == [2027]
      refute 2029 in PickHoldings.tradeable_seasons([], @priced)
    end

    test "matches a season sent as an integer as well as a string" do
      # Sleeper sends it both ways across payloads; a map keyed by one and
      # read with the other would silently report nothing as complete.
      assert PickHoldings.tradeable_seasons(
               [%{"season" => 2026, "status" => "complete"}],
               @priced
             ) ==
               [2027, 2028]
    end
  end

  describe "build/4" do
    test "every roster starts owning its own picks" do
      holdings = PickHoldings.build([], [], [2027], rounds: 2, roster_ids: [1, 2])

      assert Enum.sort_by(holdings[1], & &1.round) == [
               %{season: 2027, round: 1},
               %{season: 2027, round: 2}
             ]

      assert length(holdings[2]) == 2
    end

    test "a traded pick moves to its current owner and leaves the original" do
      traded = [%{"season" => "2027", "round" => 1, "roster_id" => 1, "owner_id" => 2}]
      holdings = PickHoldings.build([], traded, [2027], rounds: 2, roster_ids: [1, 2])

      refute %{season: 2027, round: 1} in holdings[1]
      assert %{season: 2027, round: 1} in holdings[2]
      # Roster 2 now holds its own first and roster 1's.
      assert Enum.count(holdings[2], &(&1.round == 1)) == 2
    end

    test "a completed season contributes no picks at all" do
      drafts = [%{"season" => "2026", "status" => "complete"}]
      holdings = PickHoldings.build(drafts, [], [2026], rounds: 4, roster_ids: [1])

      assert holdings == %{}
    end

    test "survives a league with no traded picks" do
      holdings = PickHoldings.build([], [], [2027, 2028], rounds: 1, roster_ids: [1])
      assert length(holdings[1]) == 2
    end
  end
end
