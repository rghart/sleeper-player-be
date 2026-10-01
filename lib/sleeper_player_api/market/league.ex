defmodule SleeperPlayerApi.Market.League do
  @moduledoc "A league seen by the market crawl, with its format. See the migration."
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}
  schema "market_leagues" do
    field :season, :string
    field :league_type, :integer
    field :te_premium, :float
    field :ppr, :float
    field :total_rosters, :integer
    field :users_crawled_at, :utc_datetime

    timestamps()
  end
end
