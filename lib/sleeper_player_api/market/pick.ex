defmodule SleeperPlayerApi.Market.Pick do
  @moduledoc "One pick in a market-corpus draft."
  use Ecto.Schema

  @primary_key false
  schema "market_picks" do
    field :draft_id, :integer
    field :pick_no, :integer
    field :round, :integer
    field :player_id, :string
  end
end
