defmodule SleeperPlayerApiWeb.PlayerController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Sleeper
  alias SleeperPlayerApi.Sleeper.Player

  action_fallback SleeperPlayerApiWeb.FallbackController

  def index(conn, _params) do
    players = Sleeper.list_players()
    render(conn, :index, players: players)
  end

  def active(conn, _params) do
    players = Sleeper.list_active_players()
    render(conn, :active, players: players)
  end

  def show(conn, %{"id" => id}) do
    player = Sleeper.get_player!(id)
    render(conn, :show, player: player)
  end

  def create(conn, %{"player" => player_params}) do
    with {:ok, %Player{} = player} <- Sleeper.create_player(player_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/players/#{player}")
      |> render(:show, player: player)
    end
  end

  def update(conn, %{"id" => id, "player" => player_params}) do
    player = Sleeper.get_player!(id)

    with {:ok, %Player{} = player} <- Sleeper.update_player(player, player_params) do
      render(conn, :show, player: player)
    end
  end

  def delete(conn, %{"id" => id}) do
    player = Sleeper.get_player!(id)

    with {:ok, %Player{}} <- Sleeper.delete_player(player) do
      send_resp(conn, :no_content, "")
    end
  end
end
