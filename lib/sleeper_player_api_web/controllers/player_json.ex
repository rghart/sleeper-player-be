defmodule SleeperPlayerApiWeb.PlayerJSON do
  alias SleeperPlayerApi.Sleeper.Player

  @doc """
  Renders a list of players.
  """
  def index(%{players: players}) do
    %{data: for(player <- players, do: data(player))}
  end

  @doc """
  Renders a list of active players.
  """
  def active(%{players: players}) do
    %{data: for(player <- players, do: data(player))}
  end

  @doc """
  Renders a map of active players.
  """
  def legacy(%{players: players}) do
    Map.new(players, fn p -> {p.player_id, data(p)} end)
  end

  @doc """
  Renders a single player.
  """
  def show(%{player: player}) do
    %{data: data(player)}
  end

  defp data(%Player{} = player) do
    %{
      id: player.id,
      active: player.active,
      age: player.age,
      fantasy_positions: Enum.map(Map.get(player, :fantasy_positions, []), fn p -> p.abbreviation end),
      first_name: player.first_name,
      last_name: player.last_name,
      full_name: player.full_name,
      player_id: player.player_id,
      position: (if player.position, do: player.position.abbreviation, else: nil),
      search_first_name: player.search_first_name,
      search_last_name: player.search_last_name,
      search_full_name: player.search_full_name,
      search_rank: player.search_rank,
      status: (if player.status, do: player.status.status, else: nil),
      years_exp: player.years_exp,
      team: (if player.team, do: player.team.abbreviation, else: nil)
    }
  end
end
