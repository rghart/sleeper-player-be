defmodule SleeperPlayerApi.Client.FantasyCalcTest do
  # Bypass owns a real port per test and this module points the client at it
  # via a shared Application env key, same trick as `test/clients/sleeper_test.exs`
  # — this suite can't run concurrently with itself or anything else that
  # touches :fantasy_calc_base_url.
  use ExUnit.Case, async: false

  alias SleeperPlayerApi.Client.FantasyCalc

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :fantasy_calc_base_url,
      "http://localhost:#{bypass.port}"
    )

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :fantasy_calc_base_url)
    end)

    {:ok, bypass: bypass}
  end

  describe "get/0 (non-raising, default URL)" do
    test "hits /values/current with the plan's fixed query params and decodes the body", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        assert conn.query_string == "isDynasty=true&numQbs=2&numTeams=12&ppr=1"
        Plug.Conn.resp(conn, 200, ~s([{"value": 100}]))
      end)

      assert FantasyCalc.get() == {:ok, [%{"value" => 100}]}
    end

    test "returns a tagged error on 429, instead of raising", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert FantasyCalc.get() == {:error, {:http_error, 429}}
    end

    test "returns a tagged error on a 5xx, instead of raising", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 503, "service unavailable")
      end)

      assert FantasyCalc.get() == {:error, {:http_error, 503}}
    end

    test "returns a tagged error on a connection failure, instead of raising", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:transport_error, _reason}} = FantasyCalc.get()
    end

    test "returns a tagged error instead of raising on a non-JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 200, "<html>not json</html>")
      end)

      assert FantasyCalc.get() == {:error, {:invalid_json, 200}}
    end
  end
end
