defmodule SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCutTest do
  # Bypass owns a real port and this module points both the KTC client and the
  # crosswalk fetch at it, same as the other Bypass-backed suites here.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel.MarketValuesCache
  alias SleeperPlayerApi.Intel.PlayerIdCrosswalk
  alias SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCut

  # A real slice of the live payload (2026-08-12), trimmed to the fields this
  # source reads: a star, a mid-tier receiver, a rookie, and a draft pick —
  # the pick being the case that must NOT produce a value row.
  @players [
    %{
      "playerName" => "Jahmyr Gibbs",
      "playerID" => 1415,
      "position" => "RB",
      "draftYear" => 2023,
      "mflid" => 16_162,
      "oneQBValues" => %{"value" => 9999, "rank" => 1, "positionalRank" => 1},
      "superflexValues" => %{"value" => 9997, "rank" => 1, "positionalRank" => 1}
    },
    %{
      "playerName" => "Zay Flowers",
      "playerID" => 1443,
      "position" => "WR",
      "draftYear" => 2023,
      "mflid" => 16_190,
      "oneQBValues" => %{"value" => 6012, "rank" => 24, "positionalRank" => 12},
      "superflexValues" => %{"value" => 5359, "rank" => 41, "positionalRank" => 18}
    },
    %{
      "playerName" => "2027 Early 1st",
      "playerID" => 1702,
      "position" => "RDP",
      "draftYear" => nil,
      # Not a missing field — KTC marks picks with a zero id.
      "mflid" => 0,
      "oneQBValues" => %{"value" => 7357, "rank" => 12, "positionalRank" => 1},
      "superflexValues" => %{"value" => 7080, "rank" => 14, "positionalRank" => 1}
    }
  ]

  # Header order matters as little as possible — the parser resolves columns by
  # name — but the shape mirrors the real file, including the `NA` it uses for
  # a missing id and a quoted name sitting after both id columns.
  #
  # The `0` row is deliberately not in the real file. It is here so the
  # draft-pick test actually exercises the `mflid: 0` guard: without it the
  # pick drops because nothing is keyed `0`, and the test passes whether or
  # not the guard exists. A sabotage run caught exactly that.
  @crosswalk """
  mfl_id,sportradar_id,fantasypros_id,gsis_id,pff_id,sleeper_id,name
  16162,abc,1,00-1,NA,9509,Jahmyr Gibbs
  16190,def,2,00-2,NA,9500,Zay Flowers
  17472,ghi,3,00-3,NA,13100,Jeremiyah Love
  15024,jkl,4,00-4,NA,NA,No Sleeper Id
  0,pqr,6,00-6,NA,4242,Not A Real Player
  0634,mno,5,00-5,NA,NA,"Bennett,Michael"
  """

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

    {:ok, bypass: bypass}
  end

  defp page(players) do
    """
    <html><body><script>
    var somethingElse = [1,2,3];
    var playersArray = #{Jason.encode!(players)};
    </script></body></html>
    """
  end

  defp stub(bypass, players) do
    Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 200, page(players))
    end)

    Bypass.stub(bypass, "GET", "/crosswalk.csv", fn conn ->
      Plug.Conn.resp(conn, 200, @crosswalk)
    end)
  end

  test "shapes both variants for each joinable player", %{bypass: bypass} do
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()

    gibbs = Enum.filter(entries, &(&1.player_id == 9509))

    assert [
             %{source: "keeptradecut:1qb", value: 9999.0, overall_rank: 1, draft_year: 2023},
             %{source: "keeptradecut:sf", value: 9997.0, overall_rank: 1}
           ] = Enum.sort_by(gibbs, & &1.source)
  end

  test "1QB and superflex are separate rows and do not overwrite each other", %{bypass: bypass} do
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()

    flowers = Enum.filter(entries, &(&1.player_id == 9500)) |> Enum.sort_by(& &1.source)

    # The whole point of keying the variant into `source`: these are genuinely
    # different numbers for the same player, and `player_values` is keyed
    # (player_id, source).
    assert [%{value: 6012.0, overall_rank: 24}, %{value: 5359.0, overall_rank: 41}] = flowers
    assert Enum.map(flowers, & &1.source) == ["keeptradecut:1qb", "keeptradecut:sf"]
  end

  test "draft picks produce no rows, since mflid 0 is not a player", %{bypass: bypass} do
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()

    # Two players, two variants each. The pick contributes nothing, and in
    # particular does not join to the id the fixture crosswalk deliberately
    # holds at 0 — which is what makes this test about the guard rather than
    # about the crosswalk happening to lack that row.
    assert length(entries) == 4
    refute Enum.any?(entries, &(&1.player_id == 4242))
    refute Enum.any?(entries, &(&1.value == 7357.0))
  end

  test "roster_percent and trade_frequency stay nil rather than borrowing KTC's own figures", %{
    bypass: bypass
  } do
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()
    assert Enum.all?(entries, &(&1.roster_percent == nil and &1.trade_frequency == nil))
  end

  test "a player the crosswalk cannot resolve is dropped, not failed over", %{bypass: bypass} do
    unknown = %{
      "playerName" => "Nobody",
      "playerID" => 99,
      "position" => "WR",
      "mflid" => 999_999,
      "oneQBValues" => %{"value" => 100, "rank" => 400, "positionalRank" => 200},
      "superflexValues" => %{"value" => 90, "rank" => 410, "positionalRank" => 205}
    }

    stub(bypass, @players ++ [unknown])

    assert {:ok, entries} = KeepTradeCut.fetch_values()
    assert length(entries) == 4
  end

  test "a payload where nothing joins is an error, not an empty success", %{bypass: bypass} do
    # The failure mode this guards: a renamed field or an error page served
    # with a 200 would otherwise upsert zero rows and look like a quiet
    # success, leaving stale values in place with no signal.
    stub(bypass, [%{"playerName" => "Nobody", "mflid" => 999_999, "oneQBValues" => %{}}])

    assert {:error, :no_joinable_players} = KeepTradeCut.fetch_values()
  end

  test "a page with no playersArray is an error rather than an empty list", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 200, "<html><body>redesigned</body></html>")
    end)

    assert {:error, :players_array_not_found} = KeepTradeCut.fetch_values()
  end

  test "a non-2xx from KTC propagates and never reaches the crosswalk", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 503, "boom")
    end)

    assert {:error, {:http_error, 503}} = KeepTradeCut.fetch_values()
  end

  test "a crosswalk failure fails the fetch rather than joining nothing", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 200, page(@players))
    end)

    Bypass.expect_once(bypass, "GET", "/crosswalk.csv", fn conn ->
      Plug.Conn.resp(conn, 500, "nope")
    end)

    assert {:error, {:http_error, 500}} = KeepTradeCut.fetch_values()
  end

  describe "crosswalk parsing" do
    test "resolves columns by header name, not position" do
      reordered = """
      sleeper_id,name,mfl_id
      9509,Jahmyr Gibbs,16162
      """

      assert PlayerIdCrosswalk.parse(reordered) == %{"16162" => "9509"}
    end

    test "skips NA ids and keeps a quoted name from shifting the id columns" do
      parsed = PlayerIdCrosswalk.parse(@crosswalk)

      assert parsed["16162"] == "9509"
      assert parsed["17472"] == "13100"
      # `NA` in either column means there is nothing to join.
      refute Map.has_key?(parsed, "15024")
      refute Map.has_key?(parsed, "0634")
    end

    test "a file without the expected headers parses to an empty map" do
      assert PlayerIdCrosswalk.parse("a,b,c\n1,2,3\n") == %{}
    end
  end
end
