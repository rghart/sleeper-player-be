defmodule SleeperPlayerApi.Client.SleeperTest do
  # Bypass owns a real port per test and this module points the client at it
  # via a shared Application env key, so this suite can't run concurrently
  # with itself (or anything else that touches :sleeper_base_url).
  use ExUnit.Case, async: false

  alias SleeperPlayerApi.Client.Sleeper

  setup do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :sleeper_base_url)
    end)

    {:ok, bypass: bypass}
  end

  describe "get!/1 (unchanged, raising, used by GetSleeperPlayerData)" do
    test "decodes a JSON body on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/players/nfl", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"1": {"player_id": "1"}}))
      end)

      response = Sleeper.get!("/players/nfl")

      assert response.body == %{"1" => %{"player_id" => "1"}}
    end

    test "raises on a transport error", %{bypass: bypass} do
      Bypass.down(bypass)

      assert_raise HTTPoison.Error, fn ->
        Sleeper.get!("/players/nfl")
      end
    end
  end

  describe "get/1 (non-raising)" do
    test "returns {:ok, decoded_body} on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/players/nfl", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"1": {"player_id": "1"}}))
      end)

      assert Sleeper.get("/players/nfl") == {:ok, %{"1" => %{"player_id" => "1"}}}
    end

    test "returns a tagged error on 429, instead of raising", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/players/nfl", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert Sleeper.get("/players/nfl") == {:error, {:http_error, 429}}
    end

    test "returns a tagged error on a 5xx, instead of raising", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/players/nfl", fn conn ->
        Plug.Conn.resp(conn, 503, "service unavailable")
      end)

      assert Sleeper.get("/players/nfl") == {:error, {:http_error, 503}}
    end

    test "returns a tagged error on a connection failure, instead of raising", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:transport_error, _reason}} = Sleeper.get("/players/nfl")
    end

    test "returns a tagged error instead of raising on a non-JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/players/nfl", fn conn ->
        Plug.Conn.resp(conn, 200, "<html>not json</html>")
      end)

      assert Sleeper.get("/players/nfl") == {:error, {:invalid_json, 200}}
    end
  end
end
