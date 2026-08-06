defmodule SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalcTest do
  # Same Bypass-owns-a-port trick as `Client.FantasyCalcTest` — can't run
  # concurrently with anything else touching :fantasy_calc_base_url.
  use ExUnit.Case, async: false

  alias SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalc

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

  defp entry(player_overrides, value \\ 5000) do
    player =
      Map.merge(
        %{"name" => "Test Player", "sleeperId" => "9001", "position" => "WR"},
        player_overrides
      )

    %{
      "player" => player,
      "value" => value,
      "overallRank" => 10,
      "positionRank" => 3,
      "maybeRosterPercent" => 0.85,
      "maybeTradeFrequency" => 0.01
    }
  end

  test "name/0 is the player_values.source discriminator" do
    assert FantasyCalc.name() == "fantasycalc"
  end

  describe "fetch_values/0" do
    test "shapes a rookie entry (with maybeDraftInfo) into the value_entry contract", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        payload = [
          entry(
            %{
              "sleeperId" => "13353",
              "maybeDraftInfo" => %{"year" => 2026, "round" => 3, "pick" => 7}
            },
            4200
          )
        ]

        Plug.Conn.resp(conn, 200, Jason.encode!(payload))
      end)

      assert {:ok, [value]} = FantasyCalc.fetch_values()

      assert value.player_id == 13353
      assert value.source == "fantasycalc"
      assert value.value == 4200.0
      assert value.overall_rank == 10
      assert value.position_rank == 3
      assert value.roster_percent == 0.85
      assert value.trade_frequency == 0.01
      assert value.draft_year == 2026
      assert %DateTime{} = value.as_of
    end

    test "an entry with no maybeDraftInfo gets draft_year: nil, not dropped", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        payload = [entry(%{"sleeperId" => "13400"})]
        Plug.Conn.resp(conn, 200, Jason.encode!(payload))
      end)

      assert {:ok, [value]} = FantasyCalc.fetch_values()
      assert value.player_id == 13400
      assert value.draft_year == nil
    end

    test "an entry with no sleeperId at all is dropped, not crashed on", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        payload = [entry(%{"sleeperId" => nil}), entry(%{"sleeperId" => "13424"})]
        Plug.Conn.resp(conn, 200, Jason.encode!(payload))
      end)

      assert {:ok, [value]} = FantasyCalc.fetch_values()
      assert value.player_id == 13424
    end

    test "propagates a client-level error rather than swallowing it", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
        Plug.Conn.resp(conn, 503, "boom")
      end)

      assert FantasyCalc.fetch_values() == {:error, {:http_error, 503}}
    end
  end
end
