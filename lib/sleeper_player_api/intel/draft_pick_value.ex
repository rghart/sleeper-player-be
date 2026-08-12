defmodule SleeperPlayerApi.Intel.DraftPickValue do
  @moduledoc """
  What a rookie draft pick is worth, per source and per league variant.

  A pick is not a player, so it cannot live in `player_values` — that table is
  keyed by a Sleeper player id. KeepTradeCut publishes picks alongside players
  in the same payload, marked `mflid: 0`.

  `tier` is `"early"`, `"mid"` or `"late"`. All three are stored for every
  `(season, round)` because a Sleeper traded pick does not know which it will
  become — see the migration for why that choice belongs to the caller rather
  than to storage.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @tiers ~w(early mid late)

  @primary_key false
  schema "draft_pick_values" do
    field :season, :integer
    field :round, :integer
    field :tier, :string
    field :source, :string
    field :value, :float
    field :overall_rank, :integer
    field :position_rank, :integer
    field :as_of, :utc_datetime

    timestamps()
  end

  @doc "The tiers KTC prices, best first."
  def tiers, do: @tiers

  @doc false
  def changeset(pick_value, attrs) do
    pick_value
    |> cast(attrs, [
      :season,
      :round,
      :tier,
      :source,
      :value,
      :overall_rank,
      :position_rank,
      :as_of
    ])
    |> validate_required([:season, :round, :tier, :source])
    |> validate_inclusion(:tier, @tiers)
    |> unique_constraint([:season, :round, :tier, :source])
  end
end
