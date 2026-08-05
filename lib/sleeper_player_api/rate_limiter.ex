defmodule SleeperPlayerApi.RateLimiter do
  @moduledoc """
  A token-bucket rate limiter shared by every caller of the Sleeper client.

  Sleeper's documented ceiling is 1000 calls/min. A single cold crawl is only
  ~83 calls, but concurrent crawls for different leagues can stack, so the
  limit has to be enforced centrally rather than trusted to each caller.
  Every request goes through `throttle/1` before it hits the network.

  Configure the ceiling in config, e.g.:

      config :sleeper_player_api, SleeperPlayerApi.RateLimiter,
        calls_per_minute: 300

  The default (300/min, well under Sleeper's 1000/min) is a deliberate
  choice, not a technical ceiling: this is someone else's API, and leaving
  headroom for other clients hitting it matters more than squeezing out
  throughput.
  """

  use GenServer

  @default_calls_per_minute 300

  # Public API

  @doc """
  Starts the rate limiter.

  Options:

    * `:name` - the process name to register (defaults to `__MODULE__`;
      pass `name: nil` to start an unnamed, unregistered process, which is
      how tests get an isolated bucket instead of sharing the global one)
    * `:calls_per_minute` - overrides the configured/default rate
    * `:capacity` - the bucket size, i.e. how many calls can burst through
      before throttling kicks in (defaults to `:calls_per_minute`)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Blocks the calling process until a token is available, then consumes one.
  """
  def throttle(server \\ __MODULE__) do
    case GenServer.call(server, :acquire, :infinity) do
      :ok ->
        :ok

      {:wait, ms} ->
        Process.sleep(ms)
        throttle(server)
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    calls_per_minute =
      Keyword.get_lazy(opts, :calls_per_minute, fn ->
        :sleeper_player_api
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:calls_per_minute, @default_calls_per_minute)
      end)

    capacity = Keyword.get(opts, :capacity, calls_per_minute) * 1.0

    state = %{
      capacity: capacity,
      tokens: capacity,
      refill_per_ms: calls_per_minute / 60_000,
      last_refill: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_refill
    tokens = min(state.capacity, state.tokens + elapsed * state.refill_per_ms)

    if tokens >= 1.0 do
      {:reply, :ok, %{state | tokens: tokens - 1.0, last_refill: now}}
    else
      missing = 1.0 - tokens
      wait_ms = missing / state.refill_per_ms
      {:reply, {:wait, max(ceil(wait_ms), 1)}, %{state | tokens: tokens, last_refill: now}}
    end
  end
end
