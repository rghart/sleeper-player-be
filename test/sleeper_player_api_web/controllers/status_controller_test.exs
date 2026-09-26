defmodule SleeperPlayerApiWeb.StatusControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Intel.ValueStatus
  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Tasks.RefreshKtcValues

  setup do
    ValueStatus.reset()
    on_exit(&ValueStatus.reset/0)
  end

  defp store(source, hours_ago) do
    as_of =
      DateTime.utc_now()
      |> DateTime.add(-hours_ago * 3600, :second)
      |> DateTime.truncate(:second)

    Repo.insert!(%PlayerValue{player_id: 1, source: source, value: 1.0, as_of: as_of})
  end

  defp source(body, name), do: Enum.find(body["sources"], &(&1["name"] == name))

  test "reports every source fresh when each is inside its limit", %{conn: conn} do
    store("keeptradecut:sf", 1)
    store("keeptradecut:1qb", 1)
    store("fantasycalc", 20)

    body = conn |> get(~p"/api/v1/status") |> json_response(200)

    assert %{"stale" => false, "maxAgeHours" => 3, "asOf" => as_of} = source(body, "KeepTradeCut")
    assert is_binary(as_of)
    assert %{"stale" => false, "maxAgeHours" => 30} = source(body, "FantasyCalc")
    assert body["unrecognizedPicks"] == %{"count" => 0, "examples" => []}
  end

  test "one stale KTC variant makes KeepTradeCut stale, even with the other fresh", %{conn: conn} do
    store("keeptradecut:sf", 1)
    store("keeptradecut:1qb", 6)
    store("fantasycalc", 5)

    body = conn |> get(~p"/api/v1/status") |> json_response(200)

    assert %{"stale" => true} = source(body, "KeepTradeCut")
    assert %{"stale" => false} = source(body, "FantasyCalc")
  end

  test "a source with nothing stored is stale, with no date", %{conn: conn} do
    store("fantasycalc", 5)

    body = conn |> get(~p"/api/v1/status") |> json_response(200)

    assert %{"stale" => true, "asOf" => nil} = source(body, "KeepTradeCut")
  end

  test "reports the picks the last KTC refresh could not read", %{conn: conn} do
    ValueStatus.record_unrecognized_picks([
      %{"playerName" => "2027 1.04"},
      %{"playerName" => "2027 1.05"}
    ])

    body = conn |> get(~p"/api/v1/status") |> json_response(200)

    assert body["unrecognizedPicks"] == %{"count" => 2, "examples" => ["2027 1.04", "2027 1.05"]}
  end

  describe "after a real KTC refresh" do
    # The status reads what the refresh writes, so one test runs the real
    # ingest rather than seeding rows the refresh might not produce - a
    # renamed source string would otherwise pass every test above.
    setup do
      bypass = Bypass.open()
      base = "http://localhost:#{bypass.port}"
      Application.put_env(:sleeper_player_api, :keep_trade_cut_base_url, base)
      Application.put_env(:sleeper_player_api, :player_id_crosswalk_url, base <> "/crosswalk.csv")
      MarketValuesCache.clear()

      on_exit(fn ->
        Application.delete_env(:sleeper_player_api, :keep_trade_cut_base_url)
        Application.delete_env(:sleeper_player_api, :player_id_crosswalk_url)
        MarketValuesCache.clear()
      end)

      players = [
        %{
          "playerName" => "Jahmyr Gibbs",
          "mflid" => 16_162,
          "oneQBValues" => %{"value" => 9999, "rank" => 1, "positionalRank" => 1},
          "superflexValues" => %{"value" => 9997, "rank" => 1, "positionalRank" => 1}
        }
      ]

      Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<script type=\"application/json\" id=\"ktc-players\">#{Jason.encode!(players)}</script>"
        )
      end)

      Bypass.stub(bypass, "GET", "/crosswalk.csv", fn conn ->
        Plug.Conn.resp(conn, 200, "mfl_id,sleeper_id,name\n16162,9509,Jahmyr Gibbs\n")
      end)

      :ok
    end

    test "KeepTradeCut reads fresh", %{conn: conn} do
      assert {:ok, _} = RefreshKtcValues.refresh()

      body = conn |> get(~p"/api/v1/status") |> json_response(200)

      assert %{"stale" => false} = source(body, "KeepTradeCut")
    end
  end
end
