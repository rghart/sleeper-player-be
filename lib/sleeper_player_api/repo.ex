defmodule SleeperPlayerApi.Repo do
  use Ecto.Repo,
    otp_app: :sleeper_player_api,
    adapter: Ecto.Adapters.Postgres
end
