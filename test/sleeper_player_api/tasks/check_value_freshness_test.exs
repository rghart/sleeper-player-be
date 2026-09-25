defmodule SleeperPlayerApi.Tasks.CheckValueFreshnessTest do
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Tasks.CheckValueFreshness
  alias SleeperPlayerApi.Tasks.RefreshKtcValues

  @now ~U[2026-09-25 12:45:00Z]

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :alert_push_url,
      "http://localhost:#{bypass.port}/alerts"
    )

    CheckValueFreshness.reset()

    # Every push lands here, in order, so a test can read exactly what would
    # have reached the phone.
    test_pid = self()

    Bypass.stub(bypass, "POST", "/alerts", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      title = conn |> Plug.Conn.get_req_header("title") |> List.first()
      send(test_pid, {:pushed, title, body})
      Plug.Conn.resp(conn, 200, "{}")
    end)

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :alert_push_url)
      CheckValueFreshness.reset()
    end)

    {:ok, bypass: bypass}
  end

  defp store(source, as_of) do
    Repo.insert!(%PlayerValue{player_id: 1, source: source, value: 1.0, as_of: as_of})
  end

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp all_fresh do
    store("keeptradecut:sf", hours_ago(1))
    store("keeptradecut:1qb", hours_ago(1))
    store("fantasycalc", hours_ago(5))
  end

  test "fresh sources send nothing" do
    all_fresh()

    assert [{"KeepTradeCut", :fresh}, {"FantasyCalc", :fresh}] = CheckValueFreshness.check(@now)
    refute_received {:pushed, _, _}
  end

  test "a stale source pushes once, naming how old it is" do
    store("keeptradecut:sf", ~U[2026-09-08 05:15:01Z])
    store("keeptradecut:1qb", ~U[2026-09-08 05:15:01Z])
    store("fantasycalc", hours_ago(5))

    assert [{"KeepTradeCut", :stale}, {"FantasyCalc", :fresh}] = CheckValueFreshness.check(@now)

    assert_received {:pushed, "KeepTradeCut values are stale", body}
    assert body =~ "2026-09-08 05:15 UTC"
    assert body =~ "415h ago"
    refute_received {:pushed, _, _}
  end

  test "one stale variant is enough, even when the other is fresh" do
    store("keeptradecut:sf", hours_ago(1))
    store("keeptradecut:1qb", hours_ago(6))
    store("fantasycalc", hours_ago(5))

    assert [{"KeepTradeCut", :stale} | _] = CheckValueFreshness.check(@now)
    assert_received {:pushed, "KeepTradeCut values are stale", _}
  end

  test "a source with nothing stored at all is stale" do
    store("fantasycalc", hours_ago(5))

    assert [{"KeepTradeCut", :stale} | _] = CheckValueFreshness.check(@now)
    assert_received {:pushed, "KeepTradeCut values are stale", body}
    assert body =~ "No KeepTradeCut values are stored"
  end

  test "stays quiet hour to hour, reminds after a day, and says when it recovers" do
    store("keeptradecut:sf", hours_ago(10))
    store("keeptradecut:1qb", hours_ago(10))
    store("fantasycalc", hours_ago(5))

    CheckValueFreshness.check(@now)
    assert_received {:pushed, "KeepTradeCut values are stale", _}

    CheckValueFreshness.check(DateTime.add(@now, 3600, :second))
    refute_received {:pushed, _, _}

    CheckValueFreshness.check(DateTime.add(@now, 24 * 3600, :second))
    assert_received {:pushed, "KeepTradeCut values are stale", _}

    Repo.update_all(PlayerValue, set: [as_of: DateTime.add(@now, 24 * 3600, :second)])

    assert [{"KeepTradeCut", :recovered}, {"FantasyCalc", :fresh}] =
             CheckValueFreshness.check(DateTime.add(@now, 25 * 3600, :second))

    assert_received {:pushed, "KeepTradeCut values are refreshing again", _}
  end

  test "without a push URL it still checks, and sends nothing" do
    Application.delete_env(:sleeper_player_api, :alert_push_url)
    store("fantasycalc", hours_ago(5))

    assert [{"KeepTradeCut", :stale} | _] = CheckValueFreshness.check(@now)
    refute_received {:pushed, _, _}
  end

  describe "against a real KTC refresh" do
    # The check reads what the refresh writes, so one test runs the real
    # ingest rather than seeding rows the refresh might not produce - a
    # renamed source string would otherwise pass every test above.
    setup %{bypass: bypass} do
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

    test "counts a real refresh as fresh, and as stale once it is too old" do
      store("fantasycalc", DateTime.utc_now() |> DateTime.truncate(:second))
      assert {:ok, _} = RefreshKtcValues.refresh()

      assert [{"KeepTradeCut", :fresh} | _] = CheckValueFreshness.check(DateTime.utc_now())

      four_hours_on = DateTime.add(DateTime.utc_now(), 4 * 3600, :second)
      assert [{"KeepTradeCut", :stale} | _] = CheckValueFreshness.check(four_hours_on)
      assert_received {:pushed, "KeepTradeCut values are stale", _}
    end
  end
end
