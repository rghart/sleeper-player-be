defmodule SleeperPlayerApi.Market.User do
  @moduledoc "A Sleeper user on the market crawl's frontier. See the migration."
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}
  schema "market_users" do
    field :depth, :integer, default: 0
    field :crawled_at, :utc_datetime

    timestamps()
  end
end
