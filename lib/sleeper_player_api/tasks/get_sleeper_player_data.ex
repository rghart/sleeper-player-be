defmodule SleeperPlayerApi.Tasks.GetSleeperPlayerData do
  import SleeperPlayerApi.Sleeper
  alias SleeperPlayerApi.Client.Sleeper

  require Logger

#  foreign_id_cache = %{
#    positions: Map.new(Sleeper.list_positions(), fn p -> {p.abbreviation, p.id} end),
#    teams: Map.new(Sleeper.list_teams(), fn t -> {t.abbreviation, t.id} end),
#    statuses: Map.new(Sleeper.list_statuses(), fn s -> {s.status, s.id} end)
#  }

  def get_sleeper_player_data do
    Logger.info("Beginning Sleeper Player Update")
    Sleeper.get!("/players/nfl").body
    |> Map.values()
    |> Enum.each(&add_or_update_player_in_repo/1)
    Logger.info("Sleeper Player Update Complete")
  end

  def add_or_update_player_in_repo(player_data) do
    parsed_id = Integer.parse(player_data["player_id"])
    case parsed_id do
      {player_id, _} ->
        player_data = Map.put(player_data, "player_json", Jason.encode!(player_data))

        player_result = case get_player(player_id) do
          nil ->
            Map.put(player_data, "id", player_id)
            |> create_player()
          found_player ->
            update_player(found_player, player_data)
        end

        case player_result do
          {:error, changeset} ->
            Logger.error("Error", [player: loggable_player_info(changeset.changes)])
            Logger.error("Error", changeset)
          _ ->
            :ok
        end
      :error ->
        Logger.info("Skipping defense data")
    end
  end

  def loggable_player_info(player) do
    "Player: #{player.full_name}, ID: #{player.player_id}"
  end
end
