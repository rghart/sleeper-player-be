defmodule SleeperPlayerApi.Intel.TradeFinderTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.TradeFinder

  # A 1QB league starting 2 RB, 2 WR, 1 TE.
  @starters %{"QB" => 1, "RB" => 2, "WR" => 2, "TE" => 1}

  defp opts(positions, values, overrides \\ %{}) do
    Map.merge(
      %{positions: positions, values: values, starters: @starters, top_value: 10_000},
      overrides
    )
  end

  describe "starters/1" do
    test "counts dedicated slots and ignores bench" do
      assert TradeFinder.starters(~w(QB RB RB WR WR TE BN BN BN)) == %{
               "QB" => 1,
               "RB" => 2,
               "WR" => 2,
               "TE" => 1
             }
    end

    test "counts SUPER_FLEX as a quarterback slot" do
      # The reading `leagueMarketSettings` already uses, and the reason a
      # superflex league prices quarterbacks like a different sport.
      assert TradeFinder.starters(~w(QB SUPER_FLEX RB WR))["QB"] == 2
    end

    test "does not distribute FLEX, which the need model deliberately skips" do
      assert TradeFinder.starters(~w(RB WR FLEX)) == %{"RB" => 1, "WR" => 1}
    end

    test "survives a league with no roster positions" do
      assert TradeFinder.starters(nil) == %{}
    end
  end

  describe "depth/2" do
    test "counts bodies per tradeable position and ignores kickers and defences" do
      positions = %{"1" => "RB", "2" => "RB", "3" => "K", "4" => "DEF", "5" => "WR"}
      assert TradeFinder.depth(~w(1 2 3 4 5), opts(positions, %{})) == %{"RB" => 2, "WR" => 1}
    end
  end

  describe "find/3" do
    # I am deep at RB (4 for 2 slots) and thin at WR (2 for 2).
    # They are deep at WR (4) and thin at RB (2). The textbook fit.
    setup do
      positions =
        Map.new(
          [
            {"my-rb1", "RB"},
            {"my-rb2", "RB"},
            {"my-rb3", "RB"},
            {"my-rb4", "RB"},
            {"my-wr1", "WR"},
            {"my-wr2", "WR"},
            {"th-wr1", "WR"},
            {"th-wr2", "WR"},
            {"th-wr3", "WR"},
            {"th-wr4", "WR"},
            {"th-rb1", "RB"},
            {"th-rb2", "RB"}
          ],
          fn {id, pos} -> {id, pos} end
        )

      values = Map.new(Map.keys(positions), fn id -> {id, 5000} end)

      mine = %{
        user_id: 1,
        display_name: "me",
        player_ids: Map.keys(positions) |> Enum.filter(&String.starts_with?(&1, "my"))
      }

      theirs = %{
        user_id: 2,
        display_name: "them",
        player_ids: Map.keys(positions) |> Enum.filter(&String.starts_with?(&1, "th"))
      }

      {:ok, positions: positions, values: values, mine: mine, theirs: theirs}
    end

    test "finds the swap where each side gives depth and gets need", ctx do
      [best | _] = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, ctx.values))

      assert Enum.all?(best.give, &(ctx.positions[&1] == "RB"))
      assert Enum.all?(best.get, &(ctx.positions[&1] == "WR"))
      assert best.partner_name == "them"
    end

    test "both sides must want it, not just the asking one", ctx do
      # They are now deep at RB too, so taking my running back helps them
      # with nothing and no suggestion should survive.
      their_rbs = %{"th-rb3" => "RB", "th-rb4" => "RB", "th-rb5" => "RB"}
      positions = Map.merge(ctx.positions, their_rbs)
      values = Map.merge(ctx.values, Map.new(Map.keys(their_rbs), &{&1, 5000}))
      theirs = %{ctx.theirs | player_ids: ctx.theirs.player_ids ++ Map.keys(their_rbs)}

      found = TradeFinder.find(ctx.mine, [theirs], opts(positions, values))

      refute Enum.any?(found, fn s -> Enum.all?(s.give, &(positions[&1] == "RB")) end)
    end

    test "refuses a lopsided trade even when the fit is perfect", ctx do
      # Same shape as the passing case, but their receivers are worth four
      # times mine. Fit alone must not carry a fleecing.
      values =
        ctx.values
        |> Map.new(fn {id, v} ->
          {id, if(String.starts_with?(id, "th-wr"), do: 20_000, else: v)}
        end)

      assert TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values)) == []
    end

    test "a package of spare parts cannot out-sum one good player", ctx do
      # Two 5,000s raw-sum to 10,000 against one 9,000 — but adjusted, depth
      # is discounted, so this must not read as a fair 2-for-1.
      values = Map.put(ctx.values, "th-wr1", 9_000)
      found = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values))

      lopsided =
        Enum.filter(found, fn s -> length(s.give) == 2 and s.get == ["th-wr1"] end)

      assert lopsided == []
    end

    test "never suggests a player it cannot price", ctx do
      # An unpriced asset would otherwise be silently treated as free.
      #
      # This asserts the behaviour, not a particular line: the guards in
      # `spare/3` and `score/5` are redundant with each other, and removing
      # either alone leaves this green. See the comment on `spare/3`.
      values = Map.delete(ctx.values, "my-rb4")
      found = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values))

      refute Enum.any?(found, fn s -> "my-rb4" in s.give end)
    end

    test "caps suggestions per partner so one roster cannot fill the list", ctx do
      found =
        TradeFinder.find(
          ctx.mine,
          [ctx.theirs],
          opts(ctx.positions, ctx.values, %{per_partner: 1})
        )

      assert length(found) == 1
    end

    test "returns nothing rather than erroring when there is no partner", ctx do
      assert TradeFinder.find(ctx.mine, [], opts(ctx.positions, ctx.values)) == []
    end

    test "carries both the raw and adjusted gap, so the caller can show its working", ctx do
      [best | _] = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, ctx.values))

      assert is_number(best.raw_gap)
      assert is_number(best.adjusted_gap)
      assert is_number(best.give_value)
      assert is_number(best.get_value)
    end
  end
end
