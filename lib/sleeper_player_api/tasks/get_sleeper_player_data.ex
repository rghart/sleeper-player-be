defmodule SleeperPlayerApi.Tasks.GetSleeperPlayerData do
  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Sleeper.Player
  alias SleeperPlayerApi.Repo

  require Logger

  @expected_fields Enum.map(Player.__schema__(:fields), fn f -> Atom.to_string(f) end)

  def get_sleeper_player_data do
    Sleeper.get!("/players/nfl").body
    |> Map.values()
    |> Enum.each(&add_or_update_player_in_repo/1)
  end

  def convert_to_repo_player(player_data) do
    player_data
    |> Map.put("player_json", Jason.encode!(player_data))
    |> Map.take(@expected_fields)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  def add_or_update_player_in_repo(player_data) do
    player = convert_to_repo_player(player_data)

    case Repo.get_by(Player, player_id: player.player_id) do
      nil  -> %Player{}
      found_player -> found_player
    end
    |> Player.changeset(player)
    |> Repo.insert_or_update
    |> case do
      {:ok, _} -> Logger.info("Success")
      {:error, changeset} -> Logger.error("Error", [player: loggable_player_info(changeset.changes)])
    end
  end

  def loggable_player_info(player) do
    "Player: #{player.full_name}, ID: #{player.player_id}"
  end
end
