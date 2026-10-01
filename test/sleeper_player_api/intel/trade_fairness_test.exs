defmodule SleeperPlayerApi.Intel.TradeFairnessTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.TradeFairness

  test "a dead-even trade is more even than nearly every real trade" do
    # 5% of real trades had a gap of exactly 0, so not quite all of them.
    assert TradeFairness.more_even_than(0.0) == 1.0
    assert TradeFairness.more_even_than(0.01) > 0.9
  end

  test "the median real gap is more even than half of them" do
    assert_in_delta TradeFairness.more_even_than(0.2348), 0.5, 1.0e-9
  end

  test "interpolates between stored percentiles" do
    # Halfway between the 50th (0.2348) and 55th (0.2615) percentiles.
    assert_in_delta TradeFairness.more_even_than((0.2348 + 0.2615) / 2), 0.475, 1.0e-9
  end

  test "a gap past every real trade is more even than none" do
    assert TradeFairness.more_even_than(1.0) == 0.0
  end

  test "measures the gap on the larger side" do
    assert TradeFairness.gap(80.0, 100.0) == 0.2
    assert TradeFairness.gap(100.0, 80.0) == 0.2
    assert TradeFairness.gap(0, 0) == 0.0
  end
end
