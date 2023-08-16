defmodule SleeperPlayerApi.Tasks.ForeignIdCache do
  def setup() do
    :ets.new(:foreign_id_cache, [

      # gives us key=>value semantics
      :set,

      # allows any process to read/write to our table
      :public,

      # allow the ETS table to access by it's name, `:foreign_id_cache`
      :named_table,

      # favor read-locks over write-locks
      read_concurrency: true,

      # internally split the ETS table into buckets to reduce
      # write-lock contention
      write_concurrency: true,
    ])
  end

  def get(key) do
    case :ets.lookup(:foreign_id_cache, key) do
      [{_key, value}] -> value
      _ -> nil
    end
  end

  def put(key, value) do
    :ets.insert(:foreign_id_cache, {key, value})
  end
end