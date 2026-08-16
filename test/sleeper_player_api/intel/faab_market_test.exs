defmodule SleeperPlayerApi.Intel.FaabMarketTest do
  use SleeperPlayerApi.DataCase, async: true

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.FaabMarket

  @alice 111
  @bob 222

  defp league(id, attrs) do
    Intel.upsert_observed_leagues([
      Map.merge(%{id: id, season: "2026", waiver_type: 2, waiver_budget: 100}, attrs)
    ])

    id
  end

  # `created` matters: the response's window is built from it, and the window
  # is what tells a caller which market these prices came from.
  defp claim(id, league_id, player_id, bid, attrs \\ %{}) do
    Intel.upsert_observed_transactions([
      Map.merge(
        %{
          id: id,
          league_id: league_id,
          week: 1,
          type: "waiver",
          status: "complete",
          created: ~U[2026-06-15 12:00:00Z],
          creator: @alice,
          participant_ids: [@alice],
          adds: %{player_id => 1},
          drops: %{},
          waiver_bid: bid
        },
        attrs
      )
    ])
  end

  describe "prices/1" do
    # The whole reason `waiver_budget` is stored. 50 of 100 and 50 of 1000 are
    # not the same bid, and a version that averaged the raw numbers would call
    # both of these 50.
    test "prices a bid as a share of its own league's budget, not as a number" do
      league(900, %{waiver_budget: 100})
      league(901, %{waiver_budget: 1000})
      claim(1, 900, "4034", 50)
      claim(2, 901, "4034", 50)

      assert %{"4034" => %{median: 27.5, low: 5.0, high: 50.0, claims: 2, leagues: 2}} =
               FaabMarket.prices().players
    end

    test "reports the spread, not just the middle" do
      # Players in this corpus routinely span 0% to 100%, so a median alone
      # would describe a price nobody paid twice.
      league(900, %{})
      league(901, %{})
      league(902, %{})
      claim(1, 900, "4034", 0)
      claim(2, 901, "4034", 30)
      claim(3, 902, "4034", 100)

      assert %{"4034" => %{median: 30.0, low: 0.0, high: 100.0}} = FaabMarket.prices().players
    end

    # A bid that lost did not buy the player. Averaging it into the price
    # reports money nobody paid.
    test "a failed claim is counted apart, never priced in" do
      league(900, %{})
      claim(1, 900, "4034", 10)
      claim(2, 900, "4034", 90, %{status: "failed"})

      assert %{"4034" => %{median: 10.0, high: 10.0, claims: 1, failed: 1}} =
               FaabMarket.prices().players
    end

    # Sleeper stores `waiver_bid` on every transaction whatever the waiver
    # system, so a rolling-waivers league contributes zeros that are not bids.
    test "leagues that do not bid are excluded, not counted as bids of nothing" do
      league(900, %{waiver_budget: 100})
      league(901, %{waiver_type: 0, waiver_budget: 100})
      claim(1, 900, "4034", 40)
      claim(2, 901, "4034", 0)

      assert %{"4034" => %{median: 40.0, claims: 1, leagues: 1}} = FaabMarket.prices().players
    end

    test "a league with no stored budget is skipped rather than assumed to be 100" do
      league(900, %{waiver_budget: nil})
      claim(1, 900, "4034", 50)

      assert FaabMarket.prices().players == %{}
    end

    # A free-agent add is not a purchase. Only `waiver` claims are bids.
    test "free agent adds are not prices" do
      league(900, %{})
      claim(1, 900, "4034", 0, %{type: "free_agent"})

      assert FaabMarket.prices().players == %{}
    end

    test "a zero bid in a bidding league is a real price and stays in" do
      # He was claimed and nobody else wanted him. That is information, and
      # dropping zeros would bias every figure upward.
      league(900, %{})
      claim(1, 900, "4034", 0)

      assert %{"4034" => %{median: 0.0, claims: 1}} = FaabMarket.prices().players
    end

    test "counts distinct leagues, so ten claims in one league cannot read as ten" do
      league(900, %{})
      claim(1, 900, "4034", 10)
      claim(2, 900, "4034", 20, %{creator: @bob})

      assert %{"4034" => %{claims: 2, leagues: 1}} = FaabMarket.prices().players
    end

    test "min_claims filters thin players out at the source" do
      league(900, %{})
      league(901, %{})
      claim(1, 900, "4034", 10)
      claim(2, 901, "4034", 20)
      claim(3, 900, "6794", 30)

      assert Map.keys(FaabMarket.prices(min_claims: 2).players) == ["4034"]
    end
  end

  describe "the sample the prices rest on" do
    test "carries the window the bids come from" do
      league(900, %{})
      claim(1, 900, "4034", 10, %{created: ~U[2026-05-02 09:00:00Z]})
      claim(2, 900, "6794", 20, %{created: ~U[2026-07-30 09:00:00Z]})

      assert %{from: ~D[2026-05-02], to: ~D[2026-07-30]} = FaabMarket.prices().window
    end

    test "counts the bidding leagues, not every league observed" do
      league(900, %{})
      league(901, %{})
      league(902, %{waiver_type: 0})

      assert FaabMarket.prices().leagues == 2
    end

    test "an empty corpus reports no window rather than an invented one" do
      assert %{window: nil, leagues: 0, players: %{}} = FaabMarket.prices()
    end
  end
end
