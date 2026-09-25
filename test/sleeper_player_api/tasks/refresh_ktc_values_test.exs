defmodule SleeperPlayerApi.Tasks.RefreshKtcValuesTest do
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.DraftPickValue
  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Intel.PlayerValueHistory
  alias SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCut
  alias SleeperPlayerApi.Tasks.RefreshKtcValues

  @crosswalk "mfl_id,sleeper_id,name\n16162,9509,Jahmyr Gibbs\n"

  @players [
    %{
      "playerName" => "Jahmyr Gibbs",
      "mflid" => 16_162,
      "draftYear" => 2023,
      "oneQBValues" => %{"value" => 9999, "rank" => 1, "positionalRank" => 1},
      "superflexValues" => %{"value" => 9997, "rank" => 1, "positionalRank" => 1}
    },
    %{
      "playerName" => "2027 Early 1st",
      "mflid" => 0,
      "oneQBValues" => %{"value" => 7357, "rank" => 12, "positionalRank" => 1},
      "superflexValues" => %{"value" => 7080, "rank" => 14, "positionalRank" => 1}
    },
    %{
      "playerName" => "2026 Late 4th",
      "mflid" => 0,
      "oneQBValues" => %{"value" => 1764, "rank" => 400, "positionalRank" => 36},
      "superflexValues" => %{"value" => 1560, "rank" => 410, "positionalRank" => 36}
    }
  ]

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

    Bypass.stub(bypass, "GET", "/crosswalk.csv", fn conn ->
      Plug.Conn.resp(conn, 200, @crosswalk)
    end)

    {:ok, bypass: bypass}
  end

  defp stub_rankings(bypass, players) do
    Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "<script type=\"application/json\" id=\"ktc-players\">#{Jason.encode!(players)}</script>" <>
          "<script>var playersArray = JSON.parse(document.getElementById('ktc-players').textContent);</script>"
      )
    end)
  end

  test "one fetch writes values, history and picks", %{bypass: bypass} do
    # `expect_once` is the point: players and picks come from the same request.
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "<script type=\"application/json\" id=\"ktc-players\">#{Jason.encode!(@players)}</script>" <>
          "<script>var playersArray = JSON.parse(document.getElementById('ktc-players').textContent);</script>"
      )
    end)

    assert {:ok, %{values: 2, history: 2, picks: 4}} = RefreshKtcValues.refresh()

    assert length(Repo.all(PlayerValue)) == 2
    assert length(Repo.all(PlayerValueHistory)) == 2
    assert length(Repo.all(DraftPickValue)) == 4
  end

  test "picks parse into season, round and tier", %{bypass: bypass} do
    stub_rankings(bypass, @players)
    assert {:ok, _} = RefreshKtcValues.refresh()

    assert %{season: 2027, round: 1, tier: "early", value: 7357.0} =
             Repo.get_by!(DraftPickValue,
               season: 2027,
               round: 1,
               tier: "early",
               source: "keeptradecut:1qb"
             )

    assert %{season: 2026, round: 4, tier: "late", value: 1560.0} =
             Repo.get_by!(DraftPickValue,
               season: 2026,
               round: 4,
               tier: "late",
               source: "keeptradecut:sf"
             )
  end

  test "a pick never lands in player_values, and a player never in pick values", %{bypass: bypass} do
    stub_rankings(bypass, @players)
    assert {:ok, _} = RefreshKtcValues.refresh()

    refute Enum.any?(Repo.all(PlayerValue), &(&1.value == 7357.0))
    assert Repo.all(PlayerValue) |> Enum.map(& &1.player_id) |> Enum.uniq() == [9509]
  end

  test "an unparseable pick name is dropped rather than priced wrong" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      KeepTradeCut.pick_entries(
        [
          %{"playerName" => "2027 Middling 1st", "oneQBValues" => %{"value" => 1}},
          %{"playerName" => "Future 1st", "oneQBValues" => %{"value" => 2}},
          %{"playerName" => "2027 Early 1st", "oneQBValues" => %{"value" => 3}}
        ],
        now
      )

    assert [%{season: 2027, round: 1, tier: "early"}] = entries
  end

  test "an exact-slot pick is stored as its slot within the round" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      KeepTradeCut.pick_entries(
        [%{"playerName" => "2027 Pick 2.11", "oneQBValues" => %{"value" => 1800}}],
        now
      )

    assert [%{season: 2027, round: 2, tier: "slot-11", value: 1800.0}] = entries
  end

  test "unrecognized_picks/1 names only rookie picks neither naming reads" do
    players = [
      %{"playerName" => "2027 Early 1st", "position" => "RDP"},
      %{"playerName" => "2027 Pick 1.04", "position" => "RDP"},
      %{"playerName" => "2027 1.04", "position" => "RDP", "pickRound" => 1, "pickNum" => 4},
      %{"playerName" => "Jahmyr Gibbs", "position" => "RB"}
    ]

    assert [%{"playerName" => "2027 1.04", "pickRound" => 1, "pickNum" => 4}] =
             KeepTradeCut.unrecognized_picks(players)
  end

  describe "picks the app cannot read" do
    setup %{bypass: bypass} do
      Application.put_env(
        :sleeper_player_api,
        :alert_push_url,
        "http://localhost:#{bypass.port}/alerts"
      )

      RefreshKtcValues.reset_alerts()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/alerts", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pushed, conn |> Plug.Conn.get_req_header("title") |> hd(), body})
        Plug.Conn.resp(conn, 200, "{}")
      end)

      on_exit(fn ->
        Application.delete_env(:sleeper_player_api, :alert_push_url)
        RefreshKtcValues.reset_alerts()
      end)

      :ok
    end

    test "push an alert naming them, once a day, and still write everything else", %{
      bypass: bypass
    } do
      odd = %{
        "playerName" => "2027 1.04",
        "position" => "RDP",
        "mflid" => 0,
        "pickRound" => 1,
        "pickNum" => 4,
        "oneQBValues" => %{"value" => 6100},
        "superflexValues" => %{"value" => 6000}
      }

      stub_rankings(bypass, @players ++ [odd])

      assert {:ok, %{values: 2}} = RefreshKtcValues.refresh()
      assert_received {:pushed, "KTC lists 1 picks the app can't read", body}
      assert body =~ ~s["2027 1.04" (pickRound 1, pickNum 4)]

      assert {:ok, _} = RefreshKtcValues.refresh()
      refute_received {:pushed, _, _}
    end

    test "send nothing when every pick is read", %{bypass: bypass} do
      stub_rankings(bypass, @players)

      assert {:ok, _} = RefreshKtcValues.refresh()
      refute_received {:pushed, _, _}
    end
  end

  test "all three tiers are kept for a season and round, since Sleeper picks carry none" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      ["2027 Early 2nd", "2027 Mid 2nd", "2027 Late 2nd"]
      |> Enum.map(&%{"playerName" => &1, "oneQBValues" => %{"value" => 100}})
      |> KeepTradeCut.pick_entries(now)

    assert Enum.map(entries, & &1.tier) |> Enum.sort() == ["early", "late", "mid"]
  end

  test "draft_pick_values/1 returns a source's picks, most valuable first", %{bypass: bypass} do
    stub_rankings(bypass, @players)
    assert {:ok, _} = RefreshKtcValues.refresh()

    values = Intel.draft_pick_values("keeptradecut:1qb") |> Enum.map(& &1.value)
    assert values == [7357.0, 1764.0]
  end

  describe "a pick the latest fetch no longer lists" do
    # KTC stops pricing a season once its rookie drafts have run. Before this,
    # the upsert-only write kept serving those 2026 picks at their last price
    # for as long as the table existed.
    @later [
      Enum.at(@players, 0),
      Enum.at(@players, 1),
      %{
        "playerName" => "2029 Mid 1st",
        "mflid" => 0,
        "oneQBValues" => %{"value" => 5100, "rank" => 30, "positionalRank" => 3},
        "superflexValues" => %{"value" => 4900, "rank" => 32, "positionalRank" => 3}
      }
    ]

    defp seasons(source) do
      source |> Intel.draft_pick_values() |> Enum.map(& &1.season) |> Enum.sort()
    end

    test "is removed by the next refresh", %{bypass: bypass} do
      stub_rankings(bypass, @players)
      assert {:ok, _} = RefreshKtcValues.refresh()
      assert seasons("keeptradecut:sf") == [2026, 2027]

      stub_rankings(bypass, @later)
      assert {:ok, %{picks: 4, pruned_picks: 2}} = RefreshKtcValues.refresh()

      assert seasons("keeptradecut:1qb") == [2027, 2029]
      assert seasons("keeptradecut:sf") == [2027, 2029]
      assert length(Repo.all(DraftPickValue)) == 4
    end

    test "is only pruned from the sources this fetch priced", %{bypass: bypass} do
      Intel.upsert_draft_pick_values([
        %{
          season: 2026,
          round: 1,
          tier: "mid",
          source: "othersource",
          value: 5000.0,
          overall_rank: nil,
          position_rank: nil,
          as_of: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      stub_rankings(bypass, @later)
      assert {:ok, _} = RefreshKtcValues.refresh()
      assert seasons("othersource") == [2026]
    end

    test "survives a refresh that fails", %{bypass: bypass} do
      stub_rankings(bypass, @players)
      assert {:ok, _} = RefreshKtcValues.refresh()

      Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
        Plug.Conn.resp(conn, 503, "boom")
      end)

      assert {:error, _} = RefreshKtcValues.refresh()
      assert seasons("keeptradecut:sf") == [2026, 2027]
    end

    test "survives a fetch that carries players but no picks at all", %{bypass: bypass} do
      # Every pick vanishing at once is what a renamed pick label looks like,
      # not KTC deciding to stop pricing picks; the last prices are kept.
      stub_rankings(bypass, @players)
      assert {:ok, _} = RefreshKtcValues.refresh()

      stub_rankings(bypass, [Enum.at(@players, 0)])
      assert {:ok, %{picks: 0, pruned_picks: 0}} = RefreshKtcValues.refresh()
      assert seasons("keeptradecut:sf") == [2026, 2027]
    end
  end

  test "a failed fetch writes nothing at all", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 503, "boom")
    end)

    assert {:error, {:http_error, 503}} = RefreshKtcValues.refresh()
    assert Repo.all(PlayerValue) == []
    assert Repo.all(DraftPickValue) == []
  end
end
