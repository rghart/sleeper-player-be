defmodule SleeperPlayerApi.Intel.TradeValueTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.TradeValue

  # The #1 asset on the board, which sets the global scale.
  @top 9999

  describe "the case the whole module exists for" do
    test "eight small pieces outweigh a stud on raw value and lose after adjustment" do
      result = TradeValue.evaluate([7000], List.duplicate(1500, 8), @top)

      # Raw sums say the package wins comfortably.
      assert result.raw_gap == 7000 - 12_000
      assert result.raw_gap < 0

      # Adjusted, the stud wins.
      assert result.adjusted_gap > 0
      assert result.one.adjusted > result.two.adjusted
    end

    test "each additional small piece is worth less than the one before it" do
      %{pieces: pieces} = TradeValue.adjust_side(List.duplicate(1500, 5), 7000, @top)

      adjusted = Enum.map(pieces, & &1.adjusted)

      # Strictly decreasing until the depth floor bites, never increasing.
      assert adjusted == Enum.sort(adjusted, :desc)
      assert List.first(adjusted) > List.last(adjusted)
    end

    test "the depth penalty floors rather than driving a piece to nothing" do
      %{pieces: pieces} = TradeValue.adjust_side(List.duplicate(1500, 12), 7000, @top)

      last = List.last(pieces).adjusted

      # 60% floor on the depth term, and a 10% floor on the base multiplier,
      # so a twelfth piece is still worth about 6% of raw — small, not zero.
      assert last > 0
      assert last / 1500 > 0.05
      assert last / 1500 < 0.10
    end
  end

  describe "relative sizing" do
    test "a piece equal to the best asset keeps a larger share of its value than half of one" do
      scale = @top + 80

      full_share = TradeValue.piece_value(7000, 7000, scale, 0) / 7000
      half_share = TradeValue.piece_value(3500, 7000, scale, 0) / 3500

      # ~16.8% against ~11.3%. Not a bigger multiple than that, because the
      # 10% floor is most of both numbers at these magnitudes — the sixth
      # power separates them (0.037 against 0.0006) but both sit on the same
      # floor. Worth knowing before reading too much into a close call: the
      # discount is real but bounded, and it is the *depth* penalty, not this
      # term, that does the heavy lifting on a wide package.
      assert full_share > half_share
      assert full_share - half_share > 0.05
    end

    test "the dominance term, not the floor, is what separates them" do
      scale = @top + 80

      # Hold the scale term constant by comparing the same value against two
      # different bests: only the dominance ratio changes.
      as_the_best = TradeValue.piece_value(3500, 3500, scale, 0)
      as_a_scrap = TradeValue.piece_value(3500, 9000, scale, 0)

      assert as_the_best > as_a_scrap
    end

    test "the best asset is taken across both sides, not per side" do
      # Same package on side two. If `best` were per-side, the eight 1500s
      # would measure against their own 1500 and look concentrated.
      with_stud = TradeValue.evaluate([7000], List.duplicate(1500, 8), @top)
      alone = TradeValue.evaluate([], List.duplicate(1500, 8), @top)

      assert with_stud.best_asset == 7000
      assert alone.best_asset == 1500
      # Measured against a 7000, the package is worth much less than when it
      # is the biggest thing in the room.
      assert with_stud.two.adjusted < alone.two.adjusted
    end
  end

  describe "ordering and shape" do
    test "the same package prices identically whatever order it arrives in" do
      shuffled = TradeValue.adjust_side([1500, 7000, 900, 4000], 7000, @top)
      sorted = TradeValue.adjust_side([7000, 4000, 1500, 900], 7000, @top)

      assert_in_delta shuffled.adjusted, sorted.adjusted, 0.000001
    end

    test "an empty side is worth zero rather than an error" do
      result = TradeValue.evaluate([], [5000], @top)

      assert result.one.adjusted == 0
      assert result.one.raw == 0
      assert result.adjusted_gap < 0
    end

    test "an all-empty trade does not divide by zero" do
      result = TradeValue.evaluate([], [], @top)
      assert result.adjusted_gap == 0
      assert result.best_asset == 0
    end

    test "a zero top value does not blow up the scale term" do
      result = TradeValue.evaluate([5000], [5000], 0)
      assert result.adjusted_gap == 0
      assert result.one.adjusted > 0
    end
  end

  describe "concentration" do
    test "one good asset beats two that sum to the same" do
      # The core claim, stated in the cleanest possible form.
      one_big = TradeValue.adjust_side([6000], 6000, @top)
      two_small = TradeValue.adjust_side([3000, 3000], 6000, @top)

      assert one_big.raw == two_small.raw
      assert one_big.adjusted > two_small.adjusted
    end

    test "two equal top assets are not penalised for being two" do
      # Neither is below half the best, so no depth penalty applies — the
      # discount is for *thinness*, not for piece count as such.
      %{pieces: pieces} = TradeValue.adjust_side([6000, 6000], 6000, @top)

      assert Enum.all?(pieces, &(&1.depth_index == 0))
      assert Enum.all?(pieces, &(not &1.small))
    end
  end
end
