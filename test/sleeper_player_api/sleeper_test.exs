defmodule SleeperPlayerApi.SleeperTest do
  use SleeperPlayerApi.DataCase

  alias SleeperPlayerApi.Sleeper

  describe "players" do
    alias SleeperPlayerApi.Sleeper.Player

    import SleeperPlayerApi.SleeperFixtures

    @invalid_attrs %{player_data: nil}

    test "list_players/0 returns all players" do
      player = player_fixture()
      assert Sleeper.list_players() == [player]
    end

    test "get_player!/1 returns the player with given id" do
      player = player_fixture()
      assert Sleeper.get_player!(player.id) == player
    end

    test "create_player/1 with valid data creates a player" do
      valid_attrs = %{player_data: %{}}

      assert {:ok, %Player{} = player} = Sleeper.create_player(valid_attrs)
      assert player.player_data == %{}
    end

    test "create_player/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sleeper.create_player(@invalid_attrs)
    end

    test "update_player/2 with valid data updates the player" do
      player = player_fixture()
      update_attrs = %{player_data: %{}}

      assert {:ok, %Player{} = player} = Sleeper.update_player(player, update_attrs)
      assert player.player_data == %{}
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
      assert %Ecto.Changeset{} = Sleeper.change_player(player)
    end
  end

  describe "players" do
    alias SleeperPlayerApi.Sleeper.Player

    import SleeperPlayerApi.SleeperFixtures

    @invalid_attrs %{active: nil, age: nil, fantasy_positions: nil, first_name: nil, full_name: nil, last_name: nil, player_data: nil, player_id: nil, position: nil, search_first_name: nil, search_full_name: nil, search_last_name: nil, search_rank: nil, status: nil, years_exp: nil}

    test "list_players/0 returns all players" do
      player = player_fixture()
      assert Sleeper.list_players() == [player]
    end

    test "get_player!/1 returns the player with given id" do
      player = player_fixture()
      assert Sleeper.get_player!(player.id) == player
    end

    test "create_player/1 with valid data creates a player" do
      valid_attrs = %{active: true, age: 42, fantasy_positions: ["option1", "option2"], first_name: "some first_name", full_name: "some full_name", last_name: "some last_name", player_data: %{}, player_id: "some player_id", position: "some position", search_first_name: "some search_first_name", search_full_name: "some search_full_name", search_last_name: "some search_last_name", search_rank: 42, status: "some status", years_exp: 42}

      assert {:ok, %Player{} = player} = Sleeper.create_player(valid_attrs)
      assert player.active == true
      assert player.age == 42
      assert player.fantasy_positions == ["option1", "option2"]
      assert player.first_name == "some first_name"
      assert player.full_name == "some full_name"
      assert player.last_name == "some last_name"
      assert player.player_data == %{}
      assert player.player_id == "some player_id"
      assert player.position == "some position"
      assert player.search_first_name == "some search_first_name"
      assert player.search_full_name == "some search_full_name"
      assert player.search_last_name == "some search_last_name"
      assert player.search_rank == 42
      assert player.status == "some status"
      assert player.years_exp == 42
    end

    test "create_player/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sleeper.create_player(@invalid_attrs)
    end

    test "update_player/2 with valid data updates the player" do
      player = player_fixture()
      update_attrs = %{active: false, age: 43, fantasy_positions: ["option1"], first_name: "some updated first_name", full_name: "some updated full_name", last_name: "some updated last_name", player_data: %{}, player_id: "some updated player_id", position: "some updated position", search_first_name: "some updated search_first_name", search_full_name: "some updated search_full_name", search_last_name: "some updated search_last_name", search_rank: 43, status: "some updated status", years_exp: 43}

      assert {:ok, %Player{} = player} = Sleeper.update_player(player, update_attrs)
      assert player.active == false
      assert player.age == 43
      assert player.fantasy_positions == ["option1"]
      assert player.first_name == "some updated first_name"
      assert player.full_name == "some updated full_name"
      assert player.last_name == "some updated last_name"
      assert player.player_data == %{}
      assert player.player_id == "some updated player_id"
      assert player.position == "some updated position"
      assert player.search_first_name == "some updated search_first_name"
      assert player.search_full_name == "some updated search_full_name"
      assert player.search_last_name == "some updated search_last_name"
      assert player.search_rank == 43
      assert player.status == "some updated status"
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
      assert %Ecto.Changeset{} = Sleeper.change_player(player)
    end
  end

  describe "players" do
    alias SleeperPlayerApi.Sleeper.Player

    import SleeperPlayerApi.SleeperFixtures

    @invalid_attrs %{active: nil, age: nil, fantasy_positions: nil, first_name: nil, full_name: nil, last_name: nil, player_id: nil, player_json: nil, position: nil, search_first_name: nil, search_full_name: nil, search_last_name: nil, search_rank: nil, status: nil, team: nil, years_exp: nil}

    test "list_players/0 returns all players" do
      player = player_fixture()
      assert Sleeper.list_players() == [player]
    end

    test "get_player!/1 returns the player with given id" do
      player = player_fixture()
      assert Sleeper.get_player!(player.id) == player
    end

    test "create_player/1 with valid data creates a player" do
      valid_attrs = %{active: true, age: 42, fantasy_positions: ["option1", "option2"], first_name: "some first_name", full_name: "some full_name", last_name: "some last_name", player_id: "some player_id", player_json: "some player_json", position: "some position", search_first_name: "some search_first_name", search_full_name: "some search_full_name", search_last_name: "some search_last_name", search_rank: 42, status: "some status", team: "some team", years_exp: 42}

      assert {:ok, %Player{} = player} = Sleeper.create_player(valid_attrs)
      assert player.active == true
      assert player.age == 42
      assert player.fantasy_positions == ["option1", "option2"]
      assert player.first_name == "some first_name"
      assert player.full_name == "some full_name"
      assert player.last_name == "some last_name"
      assert player.player_id == "some player_id"
      assert player.player_json == "some player_json"
      assert player.position == "some position"
      assert player.search_first_name == "some search_first_name"
      assert player.search_full_name == "some search_full_name"
      assert player.search_last_name == "some search_last_name"
      assert player.search_rank == 42
      assert player.status == "some status"
      assert player.team == "some team"
      assert player.years_exp == 42
    end

    test "create_player/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sleeper.create_player(@invalid_attrs)
    end

    test "update_player/2 with valid data updates the player" do
      player = player_fixture()
      update_attrs = %{active: false, age: 43, fantasy_positions: ["option1"], first_name: "some updated first_name", full_name: "some updated full_name", last_name: "some updated last_name", player_id: "some updated player_id", player_json: "some updated player_json", position: "some updated position", search_first_name: "some updated search_first_name", search_full_name: "some updated search_full_name", search_last_name: "some updated search_last_name", search_rank: 43, status: "some updated status", team: "some updated team", years_exp: 43}

      assert {:ok, %Player{} = player} = Sleeper.update_player(player, update_attrs)
      assert player.active == false
      assert player.age == 43
      assert player.fantasy_positions == ["option1"]
      assert player.first_name == "some updated first_name"
      assert player.full_name == "some updated full_name"
      assert player.last_name == "some updated last_name"
      assert player.player_id == "some updated player_id"
      assert player.player_json == "some updated player_json"
      assert player.position == "some updated position"
      assert player.search_first_name == "some updated search_first_name"
      assert player.search_full_name == "some updated search_full_name"
      assert player.search_last_name == "some updated search_last_name"
      assert player.search_rank == 43
      assert player.status == "some updated status"
      assert player.team == "some updated team"
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
      assert %Ecto.Changeset{} = Sleeper.change_player(player)
    end
  end
end