defmodule SleeperPlayerApi.RateLimiterTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.RateLimiter

  # These use a tiny, isolated bucket (`name: nil`, so it never touches the
  # globally-supervised limiter) with a fast refill rate, so the test proves
  # real throttling without sleeping for real seconds.

  test "throttle/1 refills over time instead of blocking forever" do
    # 6000 calls/min == 100 tokens/sec == 10ms per token. Capacity 2 means
    # the first two calls are free; the next three each have to wait ~10ms
    # for a token to regenerate.
    {:ok, pid} = RateLimiter.start_link(name: nil, calls_per_minute: 6000, capacity: 2)

    start = System.monotonic_time(:millisecond)
    for _ <- 1..5, do: RateLimiter.throttle(pid)
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed >= 25
  end

  test "throttle/1 does not wait while tokens are available" do
    {:ok, pid} = RateLimiter.start_link(name: nil, calls_per_minute: 6000, capacity: 10)

    start = System.monotonic_time(:millisecond)
    for _ <- 1..5, do: RateLimiter.throttle(pid)
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed < 25
  end
end
