defmodule SleeperPlayerApi.Intel.MarketValuesCache do
  @moduledoc """
  A small TTL cache for market-value fetches, keyed by the query string that
  produced them.

  ETS rather than a dependency: one table, one expiry rule, no eviction
  policy worth the name. The key space is bounded by how many distinct league
  shapes ask — a handful — and each entry is a few hundred players, so
  nothing here needs to be cleverer than "drop it when it is old".

  Reads go straight to ETS rather than through the GenServer. The process
  exists to own the table and to survive, not to serialise access: a read
  that queued behind a slow write would make this a bottleneck instead of a
  courtesy.
  """

  use GenServer

  @table __MODULE__

  # Six hours. The provider refreshes daily and the nightly job picks that up
  # at 3:30am Central, so a slice fetched on request is allowed to be some
  # hours stale - a rank list is a starting point, not a live quote, and the
  # response carries `asOf` so the caller can say how old it is.
  @default_ttl_ms 6 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The cached values for `key`, or `:miss` if absent or expired.

  An expired entry is left in place rather than deleted on read: the next
  `put/2` overwrites it, and deleting from a reader would make a read a
  write for no benefit.
  """
  @spec get(String.t()) :: {:ok, [map]} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, values, expires_at}] ->
        if now_ms() < expires_at, do: {:ok, values}, else: :miss

      [] ->
        :miss
    end
  rescue
    # The table does not exist - the cache is not running, which is possible
    # in a test that starts a bare application. A cache that is not there is a
    # miss, not a crash.
    ArgumentError -> :miss
  end

  @doc "Stores `values` under `key`, expiring after the configured TTL."
  @spec put(String.t(), [map]) :: :ok
  def put(key, values) do
    :ets.insert(@table, {key, values, now_ms() + ttl_ms()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops everything. Tests use this; nothing in production does."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    # `:public` because writers are request processes, not this one. `:named_table`
    # so readers need no handle.
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, opts}
  end

  defp ttl_ms do
    Application.get_env(:sleeper_player_api, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
