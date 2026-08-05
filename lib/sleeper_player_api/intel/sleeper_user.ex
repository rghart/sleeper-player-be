defmodule SleeperPlayerApi.Intel.SleeperUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: false}
  schema "sleeper_users" do
    field :username, :string
    field :display_name, :string
    field :avatar, :string
    field :last_crawled_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(sleeper_user, attrs) do
    sleeper_user
    |> cast(attrs, [:id, :username, :display_name, :avatar, :last_crawled_at])
    |> validate_required([:id])
  end
end
