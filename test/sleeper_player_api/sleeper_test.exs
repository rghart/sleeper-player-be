defmodule SleeperPlayerApi.SleeperTest do
  use SleeperPlayerApi.DataCase

  alias SleeperPlayerApi.Sleeper

  describe "players" do
    alias SleeperPlayerApi.Sleeper.Player

    import SleeperPlayerApi.SleeperFixtures

    @invalid_attrs %{player_id: nil}

    test "list_players/0 returns all players" do
      player = player_fixture()
      player = Map.put(player, :player_json, nil)
      assert Sleeper.list_players() == [player]
    end

    test "list_active_players/0 returns all active players" do
      _player = player_fixture(%{active: false})
      _player = Map.put(_player, :player_json, nil)
      player2 = player_fixture(%{active: true})
      player2 = Map.put(player2, :player_json, nil)
      assert Sleeper.list_active_players() == [player2]
    end

    test "get_player!/1 returns the player with given id" do
      player = player_fixture()
      assert Sleeper.get_player!(player.id) == player
    end

    test "create_player/1 with valid data creates a player" do
      valid_attrs = %{id: 1234, active: true, age: 42, first_name: "some first_name", full_name: "some full_name", last_name: "some last_name", player_id: "some player_id", player_json: "some player_json", position: "some position", search_first_name: "some search_first_name", search_full_name: "some search_full_name", search_last_name: "some search_last_name", search_rank: 42, years_exp: 42}

      assert {:ok, %Player{} = player} = Sleeper.create_player(valid_attrs)
      assert player.id == 1234
      assert player.active == true
      assert player.age == 42
      assert player.first_name == "some first_name"
      assert player.full_name == "some full_name"
      assert player.last_name == "some last_name"
      assert player.player_id == "some player_id"
      assert player.player_json == "some player_json"
      assert player.search_first_name == "some search_first_name"
      assert player.search_full_name == "some search_full_name"
      assert player.search_last_name == "some search_last_name"
      assert player.search_rank == 42
      assert player.years_exp == 42
    end

    test "create_player/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sleeper.create_player(@invalid_attrs)
    end

    test "update_player/2 with valid data updates the player" do
      player = player_fixture()
      update_attrs = %{id: 1234, active: false, age: 43, fantasy_positions: ["option1"], first_name: "some updated first_name", full_name: "some updated full_name", last_name: "some updated last_name", player_id: "some updated player_id", player_json: "some updated player_json", position: "some updated position", search_first_name: "some updated search_first_name", search_full_name: "some updated search_full_name", search_last_name: "some updated search_last_name", search_rank: 43, status: "some updated status", team: "some updated team", years_exp: 43}

      assert {:ok, %Player{} = player} = Sleeper.update_player(player, update_attrs)
      assert player.active == false
      assert player.age == 43
      assert player.first_name == "some updated first_name"
      assert player.full_name == "some updated full_name"
      assert player.last_name == "some updated last_name"
      assert player.player_id == "some updated player_id"
      assert player.player_json == "some updated player_json"
      assert player.search_first_name == "some updated search_first_name"
      assert player.search_full_name == "some updated search_full_name"
      assert player.search_last_name == "some updated search_last_name"
      assert player.search_rank == 43
      assert player.years_exp == 43
    end

    test "update_player/2 with invalid data returns error changeset" do
      player = player_fixture()
      assert {:error, %Ecto.Changeset{}} = Sleeper.update_player(player, @invalid_attrs)
      assert player == Sleeper.get_player!(player.id)
    end

    test "delete_player/1 deletes the player" do
      player = player_fixture()
      assert {:ok, %Player{}} = Sleeper.delete_player(player)
      assert_raise Ecto.NoResultsError, fn -> Sleeper.get_player!(player.id) end
    end

    test "change_player/1 returns a player changeset" do
      player = player_fixture()
      assert %Ecto.Changeset{changes: result} = Sleeper.change_player(player, %{"team" => "some other team", "status" => "some status", "position" => "some position"})
      assert result.team_id == List.first(Sleeper.list_teams()).id
      assert result.status_id == List.first(Sleeper.list_statuses()).id
      assert result.position_id == List.first(Sleeper.list_positions()).id
    end
  end

  describe "positions" do
    alias SleeperPlayerApi.Sleeper.Position

    import SleeperPlayerApi.SleeperFixtures

    @invalid_attrs %{abbreviation: nil}

    test "list_positions/0 returns all positions" do
      position = position_fixture()
      assert Sleeper.list_positions() == [position]
    end

    test "get_position_id/1 returns the position with given id" do
      position = position_fixture()
      assert Sleeper.get_position_by_abbreviation(position.abbreviation) == position
    end

    test "create_position/1 with valid data creates a position" do
      valid_attrs = %{abbreviation: "some position"}

      assert {:ok, %Position{} = position} = Sleeper.create_position(valid_attrs)
      assert position.abbreviation == "some position"
    end

    test "create_position/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sleeper.create_position(@invalid_attrs)
    end

  end
end
