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

    test "still sees shape when every roster is deep against its starting slots", ctx do
      # The case that made the first version return nothing in production.
      # District 13 rosters carry 8 RB and 9 WR against 2 starting slots each,
      # so an absolute comparison to starters calls everything deep and
      # nothing thin. Depth has to be relative to the league.
      #
      # Here both rosters are far past their starters everywhere, but mine is
      # running-back heavy and theirs is receiver heavy — which is a real
      # trade and must survive.
      extra_my_rbs = Map.new(1..4, &{"my-rb-x#{&1}", "RB"})
      extra_my_wrs = Map.new(1..3, &{"my-wr-x#{&1}", "WR"})
      extra_th_wrs = Map.new(1..4, &{"th-wr-x#{&1}", "WR"})
      extra_th_rbs = Map.new(1..3, &{"th-rb-x#{&1}", "RB"})

      positions =
        ctx.positions
        |> Map.merge(extra_my_rbs)
        |> Map.merge(extra_my_wrs)
        |> Map.merge(extra_th_wrs)
        |> Map.merge(extra_th_rbs)

      values = Map.new(Map.keys(positions), &{&1, 5000})

      mine = %{
        ctx.mine
        | player_ids: ctx.mine.player_ids ++ Map.keys(extra_my_rbs) ++ Map.keys(extra_my_wrs)
      }

      theirs = %{
        ctx.theirs
        | player_ids: ctx.theirs.player_ids ++ Map.keys(extra_th_wrs) ++ Map.keys(extra_th_rbs)
      }

      found = TradeFinder.find(mine, [theirs], opts(positions, values))

      assert found != []
      assert Enum.all?(hd(found).give, &(positions[&1] == "RB"))
      assert Enum.all?(hd(found).get, &(positions[&1] == "WR"))
    end

    test "league_average counts every roster, including the asking one", ctx do
      average =
        TradeFinder.league_average([ctx.mine, ctx.theirs], opts(ctx.positions, ctx.values))

      # 4 RB + 2 RB over two rosters, and the mirror for receivers.
      assert average["RB"] == 3.0
      assert average["WR"] == 3.0
    end

    test "adds a pick from my side when I would otherwise be getting more", ctx do
      # Their receiver is worth more than my back, so the swap is outside the
      # fairness band on its own, and a pick I own closes it.
      #
      # The pick values here are not arbitrary. A sweetener is itself
      # discounted by `TradeValue`, so it contributes roughly a tenth of its
      # raw value — a fourth-rounder cannot close a gap of this size, and a
      # first overshoots it into being unfair the other way. Only the middle
      # pick lands inside the band, which is the point: this cannot rescue
      # any trade you like.
      values =
        Map.new(ctx.values, fn {id, v} ->
          {id, if(String.starts_with?(id, "th-wr"), do: 7000, else: v)}
        end)

      overrides = %{
        my_picks: [
          %{season: 2027, round: 1},
          %{season: 2027, round: 2},
          %{season: 2027, round: 4}
        ],
        pick_values: %{{2027, 1} => 6000, {2027, 2} => 4200, {2027, 4} => 1800},
        # A sweetened 1-for-1 fits less well than an unsweetened 2-for-1
        # (the 2-for-1 fills two of their holes), so the default cap of three
        # hides every sweetened trade. Raised here to see them at all.
        per_partner: 50
      }

      found = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values, overrides))

      # Any sweetened suggestion, not the top-ranked one: the highest-*fit*
      # trade here is a 2-for-1 that is already fair and needs no sweetener at
      # all. The sweetener is what rescues the 1-for-1.
      sweetened = Enum.filter(found, &(&1.give_picks != []))

      assert sweetened != []
      assert Enum.all?(sweetened, &(&1.get_picks == []))
      assert Enum.all?(sweetened, &(&1.give_picks == [%{season: 2027, round: 2}]))
    end

    test "adds a pick from their side when they are the ones behind", ctx do
      values =
        Map.new(ctx.values, fn {id, v} ->
          {id, if(String.starts_with?(id, "my-rb"), do: 7000, else: v)}
        end)

      overrides = %{
        picks_by_user: %{"2" => [%{season: 2027, round: 2}]},
        pick_values: %{{2027, 2} => 4200},
        per_partner: 50
      }

      found = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values, overrides))

      assert Enum.any?(found, &(&1.get_picks == [%{season: 2027, round: 2}]))
    end

    test "a pick cannot manufacture a fit that the players do not have", ctx do
      # They are deep at running back too, so no player swap fits. A pick
      # closing the value gap must not rescue it — fit is decided before any
      # sweetener, on the players alone.
      their_rbs = %{"th-rb3" => "RB", "th-rb4" => "RB", "th-rb5" => "RB"}
      positions = Map.merge(ctx.positions, their_rbs)
      values = Map.merge(ctx.values, Map.new(Map.keys(their_rbs), &{&1, 5000}))
      theirs = %{ctx.theirs | player_ids: ctx.theirs.player_ids ++ Map.keys(their_rbs)}

      overrides = %{
        my_picks: [%{season: 2027, round: 1}],
        pick_values: %{{2027, 1} => 6000}
      }

      found = TradeFinder.find(ctx.mine, [theirs], opts(positions, values, overrides))

      refute Enum.any?(found, fn s -> Enum.all?(s.give, &(positions[&1] == "RB")) end)
    end

    test "a pick nobody prices is never offered", ctx do
      values =
        Map.new(ctx.values, fn {id, v} ->
          {id, if(String.starts_with?(id, "th-wr"), do: 7000, else: v)}
        end)

      overrides = %{my_picks: [%{season: 2029, round: 1}], pick_values: %{}}
      found = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, values, overrides))

      refute Enum.any?(found, &(&1.give_picks != []))
    end

    test "carries empty pick lists when no sweetener was needed", ctx do
      [best | _] = TradeFinder.find(ctx.mine, [ctx.theirs], opts(ctx.positions, ctx.values))

      assert best.give_picks == []
      assert best.get_picks == []
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
