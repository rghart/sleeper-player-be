defmodule SleeperPlayerApi.Sleeper.Status do
  use Ecto.Schema
  import Ecto.Changeset

  alias SleeperPlayerApi.Sleeper.Player

  schema "statuses" do
    field :status, :string
    has_many :players, Player

    timestamps()
  end

  @doc false
  def changeset(status, attrs) do
    status
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> unique_constraint(:status)
  end
end
