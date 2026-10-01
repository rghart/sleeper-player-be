defmodule SleeperPlayerApi.Market.Draft do
  @moduledoc "A completed dynasty draft in the market corpus. See the migration."
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}
  schema "market_drafts" do
    field :league_id, :integer
    field :season, :string
    field :kind, :string
    field :draft_type, :string
    field :teams, :integer
    field :rounds, :integer
    field :qb_slots, :integer
    field :te_premium, :float
    field :ppr, :float
    field :scoring_type, :string
    field :started_at, :utc_datetime
    field :picks_count, :integer
    field :complete, :boolean, default: false

    timestamps()
  end
end
