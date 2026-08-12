defmodule SleeperPlayerApi.Intel.PlayerValueHistory do
  @moduledoc """
  One player's value from one source on one day — the time series
  `PlayerValue` cannot be.

  `player_values` is keyed `(player_id, source)` and refreshed in place, so it
  only ever answers "what is he worth now". This table answers "what has he
  been worth", which is the question every in-season dynasty read is actually
  built on: a buy-low and a sell-high are both claims about a price *moving*.

  One row per `(player_id, source, day)`, holding that day's close — the last
  observation written on a date wins. See the migration for why the grain is
  daily rather than per-fetch, and why that means no retention job is needed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "player_value_history" do
    field :player_id, :integer
    field :source, :string
    field :day, :date
    field :value, :float
    field :overall_rank, :integer
    field :position_rank, :integer
    field :as_of, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:player_id, :source, :day, :value, :overall_rank, :position_rank, :as_of])
    |> validate_required([:player_id, :source, :day])
    |> unique_constraint([:player_id, :source, :day])
  end
end
