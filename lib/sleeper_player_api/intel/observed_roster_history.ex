defmodule SleeperPlayerApi.Intel.ObservedRosterHistory do
  @moduledoc """
  One roster in one observed league as it stood on one day — the time series
  `ObservedRoster` cannot be.

  `observed_rosters` is keyed `(league_id, roster_id)` and refreshed in place
  on every crawl, so it only ever answers "who is on this roster now". This
  table answers "who was on it then", which is the question positional need
  is actually built on: 99% of players taken in corpus drafts are still
  rostered today (measured 2026-08-09), so a current roster already contains
  the label and cannot be used to validate a prediction about the moment a
  pick was made.

  One row per `(league_id, roster_id, day)`, holding that day's close — the
  last observation written on a date wins. Written unconditionally on every
  crawl, including when nothing changed, so that a missing day means "we
  never looked" rather than being ambiguous between that and "nothing moved".
  See the migration for the measured size that trade costs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedLeague

  @primary_key false
  schema "observed_roster_history" do
    belongs_to :league, ObservedLeague, references: :id, type: :id, define_field: false
    field :league_id, :integer
    field :roster_id, :integer
    field :day, :date
    field :owner_id, :integer
    field :player_ids, {:array, :string}, default: []
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:league_id, :roster_id, :day, :owner_id, :player_ids, :fetched_at])
    |> validate_required([:league_id, :roster_id, :day])
    |> unique_constraint([:league_id, :roster_id, :day])
  end
end
