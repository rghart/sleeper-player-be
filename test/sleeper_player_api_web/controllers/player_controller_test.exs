defmodule SleeperPlayerApiWeb.PlayerControllerTest do
  use SleeperPlayerApiWeb.ConnCase


  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all players", %{conn: conn} do
      conn = get(conn, ~p"/api/players")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "active" do
    test "lists all active players", %{conn: conn} do
      conn = get(conn, ~p"/api/players/active")
      assert json_response(conn, 200)["data"] == []
    end
  end


#  @create_attrs %{
#    active: true,
#    age: 42,
#    fantasy_positions: ["option1", "option2"],
#    first_name: "some first_name",
#    full_name: "some full_name",
#    last_name: "some last_name",
#    player_id: "some player_id",
#    player_json: %{},
#    position: "some position",
#    search_first_name: "some search_first_name",
#    search_full_name: "some search_full_name",
#    search_last_name: "some search_last_name",
#    search_rank: 42,
#    status: "some status",
#    team: "some team",
#    years_exp: 42
#  }
#  @update_attrs %{
#    active: false,
#    age: 43,
#    fantasy_positions: ["option1"],
#    first_name: "some updated first_name",
#    full_name: "some updated full_name",
#    last_name: "some updated last_name",
#    player_id: "some updated player_id",
#    player_json: %{},
#    position: "some updated position",
#    search_first_name: "some updated search_first_name",
#    search_full_name: "some updated search_full_name",
#    search_last_name: "some updated search_last_name",
#    search_rank: 43,
#    status: "some updated status",
#    team: "some updated team",
#    years_exp: 43
#  }
#  @invalid_attrs %{active: nil, age: nil, fantasy_positions: nil, first_name: nil, full_name: nil, last_name: nil, player_id: nil, player_json: nil, position: nil, search_first_name: nil, search_full_name: nil, search_last_name: nil, search_rank: nil, status: nil, team: nil, years_exp: nil}

#  describe "create player" do
#    test "renders player when data is valid", %{conn: conn} do
#      conn = post(conn, ~p"/api/players", player: @create_attrs)
#      assert %{"id" => id} = json_response(conn, 201)["data"]
#
#      conn = get(conn, ~p"/api/players/#{id}")
#
#      assert %{
#               "id" => ^id,
#               "active" => true,
#               "age" => 42,
#               "fantasy_positions" => ["option1", "option2"],
#               "first_name" => "some first_name",
#               "full_name" => "some full_name",
#               "last_name" => "some last_name",
#               "player_id" => "some player_id",
#               "player_json" => %{},
#               "position" => "some position",
#               "search_first_name" => "some search_first_name",
#               "search_full_name" => "some search_full_name",
#               "search_last_name" => "some search_last_name",
#               "search_rank" => 42,
#               "status" => "some status",
#               "team" => "some team",
#               "years_exp" => 42
#             } = json_response(conn, 200)["data"]
#    end
#
#    test "renders errors when data is invalid", %{conn: conn} do
#      conn = post(conn, ~p"/api/players", player: @invalid_attrs)
#      assert json_response(conn, 422)["errors"] != %{}
#    end
#  end
#
#  describe "update player" do
#    setup [:create_player]
#
#    test "renders player when data is valid", %{conn: conn, player: %Player{id: id} = player} do
#      conn = put(conn, ~p"/api/players/#{player}", player: @update_attrs)
#      assert %{"id" => ^id} = json_response(conn, 200)["data"]
#
#      conn = get(conn, ~p"/api/players/#{id}")
#
#      assert %{
#               "id" => ^id,
#               "active" => false,
#               "age" => 43,
#               "fantasy_positions" => ["option1"],
#               "first_name" => "some updated first_name",
#               "full_name" => "some updated full_name",
#               "last_name" => "some updated last_name",
#               "player_id" => "some updated player_id",
#               "player_json" => %{},
#               "position" => "some updated position",
#               "search_first_name" => "some updated search_first_name",
#               "search_full_name" => "some updated search_full_name",
#               "search_last_name" => "some updated search_last_name",
#               "search_rank" => 43,
#               "status" => "some updated status",
#               "team" => "some updated team",
#               "years_exp" => 43
#             } = json_response(conn, 200)["data"]
#    end
#
#    test "renders errors when data is invalid", %{conn: conn, player: player} do
#      conn = put(conn, ~p"/api/players/#{player}", player: @invalid_attrs)
#      assert json_response(conn, 422)["errors"] != %{}
#    end
#  end
#
#  describe "delete player" do
#    setup [:create_player]
#
#    test "deletes chosen player", %{conn: conn, player: player} do
#      conn = delete(conn, ~p"/api/players/#{player}")
#      assert response(conn, 204)
#
#      assert_error_sent 404, fn ->
#        get(conn, ~p"/api/players/#{player}")
#      end
#    end
#  end
#
#  defp create_player(_) do
#    player = player_fixture()
#    %{player: player}
#  end
end
