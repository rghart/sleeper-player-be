defmodule SleeperPlayerApi.Intel.LeagueSnapshotCache do
  @moduledoc """
  A short TTL cache for `Intel.LeagueSnapshot`, keyed by league id.

  The league endpoints (`/rankings`, `/weaknesses`, `/sells`) each need the
  same five live Sleeper reads plus the stored values. An agent answering one
  question may call several of them in a row, and without this each call would
  repeat those reads - 15 Sleeper requests for three tools instead of 5.

  A minute is short enough that a roster move shows up almost at once, and
  long enough to cover one conversation's burst of tool calls. Same shape as
  `MarketValuesCache`: ETS owned by a process that exists only to keep the
  table alive, read directly by callers.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms 60 * 1000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The cached snapshot for `league_id`, or `:miss` if absent or expired."
  @spec get(String.t()) :: {:ok, map} | :miss
  def get(league_id) do
    case :ets.lookup(@table, league_id) do
      [{^league_id, snapshot, expires_at}] ->
        if now_ms() < expires_at, do: {:ok, snapshot}, else: :miss

      [] ->
        :miss
    end
  rescue
    # No table means the cache is not running; that is a miss, not a crash.
    ArgumentError -> :miss
  end

  @doc "Stores `snapshot` under `league_id`, expiring after the configured TTL."
  @spec put(String.t(), map) :: :ok
  def put(league_id, snapshot) do
    :ets.insert(@table, {league_id, snapshot, now_ms() + ttl_ms()})
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
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, opts}
  end

  defp ttl_ms do
    Application.get_env(:sleeper_player_api, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
