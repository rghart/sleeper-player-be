defmodule SleeperPlayerApi.Intel.ObservedTransaction do
  @moduledoc """
  One trade, waiver claim or free-agent add from a leaguemate's league
  (plan §6 step 6).

  Two things worth knowing before querying this.

  **Read it by `participant_ids`, not `creator`.** `creator` is whoever
  *initiated* the transaction; a trade has two sides and only one creator, so
  filtering on it drops every trade a manager accepted rather than proposed.
  Trades are the rarest type and the most interesting (5 of 124 for the
  heaviest leaguemate measured), so that undercount would be both invisible
  and exactly the wrong half to lose.

  **`status: "failed"` rows are kept deliberately.** A failed waiver claim is
  a revealed preference nobody else in that league can see — it is signal, not
  noise. Filter it at the point of display, with a label, rather than dropping
  it at ingest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Intel.ObservedLeague

  @primary_key {:id, :id, autogenerate: false}
  schema "observed_transactions" do
    belongs_to :league, ObservedLeague, references: :id, type: :id, define_field: false
    field :league_id, :integer
    field :week, :integer
    field :type, :string
    field :status, :string
    field :created, :utc_datetime
    field :creator, :integer
    field :participant_ids, {:array, :integer}, default: []
    # %{player_id => roster_id}, as Sleeper sends them.
    field :adds, :map
    field :drops, :map
    field :draft_picks, {:array, :map}, default: []
    field :waiver_bid, :integer

    timestamps()
  end

  @fields ~w(id league_id week type status created creator participant_ids adds drops draft_picks waiver_bid)a

  @doc false
  def changeset(observed_transaction, attrs) do
    observed_transaction
    |> cast(attrs, @fields)
    |> validate_required([:id, :league_id, :week])
  end
end
