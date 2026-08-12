defmodule SleeperPlayerApi.Tasks.BackfillKtcHistoryTest do
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Intel.PlayerValueHistory
  alias SleeperPlayerApi.Tasks.BackfillKtcHistory

  @crosswalk """
  mfl_id,sleeper_id,name
  16162,9509,Jahmyr Gibbs
  16190,9500,Zay Flowers
  """

  @players [
    %{"playerName" => "Jahmyr Gibbs", "slug" => "jahmyr-gibbs-1415", "mflid" => 16_162},
    %{"playerName" => "Zay Flowers", "slug" => "zay-flowers-1443", "mflid" => 16_190},
    # A pick: no mflid to join on, so it must never cost a request.
    %{"playerName" => "2027 Early 1st", "slug" => "2027-early-1st", "mflid" => 0}
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

    Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "<script>var playersArray = #{Jason.encode!(@players)};\n</script>"
      )
    end)

    Bypass.stub(bypass, "GET", "/crosswalk.csv", fn conn ->
      Plug.Conn.resp(conn, 200, @crosswalk)
    end)

    {:ok, bypass: bypass, base: base}
  end

  defp variant(points, ranks, position_ranks) do
    %{
      "overallValue" => Enum.map(points, fn {d, v} -> %{"d" => d, "v" => v} end),
      "overallRankHistory" => Enum.map(ranks, fn {d, v} -> %{"d" => d, "v" => v} end),
      "positionalRankHistory" => Enum.map(position_ranks, fn {d, v} -> %{"d" => d, "v" => v} end)
    }
  end

  defp player_page(one_qb, superflex) do
    """
    <script>
    var playerOneQB = #{Jason.encode!(one_qb)};
    var playerSuperflex = #{Jason.encode!(superflex)};
    </script>
    """
  end

  defp stub_players(bypass) do
    for slug <- ["jahmyr-gibbs-1415", "zay-flowers-1443"] do
      Bypass.stub(bypass, "GET", "/dynasty-rankings/players/#{slug}", fn conn ->
        one = variant([{"260810", 5942}, {"260811", 5984}], [{"260810", 44}, {"260811", 43}], [])
        sf = variant([{"260810", 5366}], [{"260810", 52}], [{"260810", 20}])
        Plug.Conn.resp(conn, 200, player_page(one, sf))
      end)
    end
  end

  test "stores a daily row per variant per day", %{bypass: bypass} do
    stub_players(bypass)

    assert {:ok, %{players: 2, failed: 0}} = BackfillKtcHistory.backfill(delay_ms: 0)

    rows = Repo.all(PlayerValueHistory)
    # 2 players x (2 one-qb days + 1 superflex day)
    assert length(rows) == 6

    gibbs =
      rows
      |> Enum.filter(&(&1.player_id == 9509 and &1.source == "keeptradecut:1qb"))
      |> Enum.sort_by(& &1.day, Date)

    assert [
             %{day: ~D[2026-08-10], value: 5942.0, overall_rank: 44},
             %{day: ~D[2026-08-11], value: 5984.0, overall_rank: 43}
           ] = gibbs
  end

  test "`since` drops earlier days but still stores later ones", %{bypass: bypass} do
    stub_players(bypass)

    assert {:ok, _} = BackfillKtcHistory.backfill(delay_ms: 0, since: ~D[2026-08-11])

    days = Repo.all(PlayerValueHistory) |> Enum.map(& &1.day) |> Enum.uniq()
    assert days == [~D[2026-08-11]]
  end

  test "ranks join on the day, not on array position" do
    # The three series are the same length in practice, but a positional zip
    # would silently pair a value with another day's rank and nothing
    # downstream could ever surface it. Here the rank series is deliberately
    # in a different order and missing a day.
    object =
      variant(
        [{"260810", 100}, {"260811", 200}],
        [{"260811", 43}, {"260810", 44}],
        [{"260811", 20}]
      )

    rows =
      BackfillKtcHistory.history_rows(object, 1, "keeptradecut:1qb", ~D[2000-01-01])
      |> Enum.sort_by(& &1.day, Date)

    assert [
             %{day: ~D[2026-08-10], value: 100.0, overall_rank: 44, position_rank: nil},
             %{day: ~D[2026-08-11], value: 200.0, overall_rank: 43, position_rank: 20}
           ] = rows
  end

  test "a day with a rank but no value produces no row" do
    object = variant([], [{"260810", 44}], [{"260810", 20}])
    assert BackfillKtcHistory.history_rows(object, 1, "keeptradecut:1qb", ~D[2000-01-01]) == []
  end

  test "as_of lands on the day it describes, so record_value_history agrees" do
    object = variant([{"230310", 6609}], [], [])
    [row] = BackfillKtcHistory.history_rows(object, 1, "keeptradecut:1qb", ~D[2000-01-01])

    assert row.day == ~D[2023-03-10]
    assert DateTime.to_date(row.as_of) == row.day
  end

  test "draft picks cost no request at all", %{bypass: bypass} do
    stub_players(bypass)

    # Bypass fails the test on a request to an un-stubbed path, so the pick's
    # slug never being fetched is what this asserts.
    Bypass.stub(bypass, "GET", "/dynasty-rankings/players/2027-early-1st", fn conn ->
      Plug.Conn.resp(conn, 500, "should never be called")
    end)

    assert {:ok, %{players: 2, failed: 0}} = BackfillKtcHistory.backfill(delay_ms: 0)
  end

  test "one player page failing does not abort the run", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/dynasty-rankings/players/jahmyr-gibbs-1415", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    Bypass.stub(bypass, "GET", "/dynasty-rankings/players/zay-flowers-1443", fn conn ->
      one = variant([{"260810", 5366}], [{"260810", 52}], [])
      Plug.Conn.resp(conn, 200, player_page(one, %{}))
    end)

    assert {:ok, %{players: 1, failed: 1}} = BackfillKtcHistory.backfill(delay_ms: 0)
    assert [%{player_id: 9500}] = Repo.all(PlayerValueHistory)
  end

  test "`limit` stops early, for a smoke run", %{bypass: bypass} do
    stub_players(bypass)

    assert {:ok, %{players: 1}} = BackfillKtcHistory.backfill(delay_ms: 0, limit: 1)
  end

  test "a failed rankings fetch aborts before any player page", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 503, "boom")
    end)

    assert {:error, {:http_error, 503}} = BackfillKtcHistory.backfill(delay_ms: 0)
    assert Repo.all(PlayerValueHistory) == []
  end
end
