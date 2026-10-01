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
      "byeWeek" => 6,
      # The healthy shape, and the common one: 425 of 500 entries carry an
      # `injuryCode` and nothing else (measured 2026-08-15).
      "injury" => %{"injuryCode" => 1},
      "oneQBValues" => %{
        "value" => 9999,
        "rank" => 1,
        "positionalRank" => 1,
        "stdLiquidity" => 41.0
      },
      "superflexValues" => %{
        "value" => 9997,
        "rank" => 1,
        "positionalRank" => 1,
        "stdLiquidity" => 35.0
      }
    },
    %{
      "playerName" => "Zay Flowers",
      "playerID" => 1443,
      "position" => "WR",
      "draftYear" => 2023,
      "mflid" => 16_190,
      "byeWeek" => 11,
      # The injured shape, verbatim from the live payload.
      "injury" => %{
        "injuryArea" => "Hamstring",
        "injuryCode" => 2,
        "injuryName" => "Questionable",
        "injuryReturn" => "Aug 22, 2026"
      },
      "oneQBValues" => %{
        "value" => 6012,
        "rank" => 24,
        "positionalRank" => 12,
        "stdLiquidity" => 12.0
      },
      "superflexValues" => %{
        "value" => 5359,
        "rank" => 41,
        "positionalRank" => 18,
        "stdLiquidity" => 9.0
      }
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

  # A tight end, kept out of `@players` so the counts above stay about the
  # players they were written for.
  @tight_end %{
    "playerName" => "Brock Bowers",
    "playerID" => 1800,
    "position" => "TE",
    "draftYear" => 2024,
    "mflid" => 16_500,
    "byeWeek" => 8,
    "injury" => %{"injuryCode" => 1},
    # Live shape: each format carries KTC's three TE-premium tiers beside
    # its base value.
    "oneQBValues" => %{
      "value" => 8009,
      "rank" => 7,
      "positionalRank" => 1,
      "tep" => %{"value" => 8863, "rank" => 4, "positionalRank" => 1},
      "tepp" => %{"value" => 9700, "rank" => 2, "positionalRank" => 1},
      "teppp" => %{"value" => 9999, "rank" => 1, "positionalRank" => 1}
    },
    "superflexValues" => %{
      "value" => 8040,
      "rank" => 6,
      "positionalRank" => 1,
      "tep" => %{"value" => 8897, "rank" => 5, "positionalRank" => 1},
      "tepp" => %{"value" => 9722, "rank" => 2, "positionalRank" => 1},
      "teppp" => %{"value" => 9999, "rank" => 1, "positionalRank" => 1}
    }
  }

  @crosswalk """
  mfl_id,sportradar_id,fantasypros_id,gsis_id,pff_id,sleeper_id,name
  16162,abc,1,00-1,NA,9509,Jahmyr Gibbs
  16190,def,2,00-2,NA,9500,Zay Flowers
  17472,ghi,3,00-3,NA,13100,Jeremiyah Love
  16500,stu,7,00-7,NA,11604,Brock Bowers
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

  # The shape KTC has served since 2026-09-08: the data in a JSON script
  # block, read back by an inline script that no longer contains it.
  defp page(players) do
    """
    <html><body>
    <script type="application/json" id="ktc-players">#{Jason.encode!(players)}</script>
    <script>
    var somethingElse = [1,2,3];
    var playersArray = JSON.parse(document.getElementById('ktc-players').textContent);
    </script></body></html>
    """
  end

  # The shape before 2026-09-08, still read as a fallback.
  defp legacy_page(players) do
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

  test "liquidity is shaped per format, not once per player", %{bypass: bypass} do
    # The reason it lives on the value row rather than beside `bye_week`: KTC
    # prices how tradeable a player is separately for 1QB and superflex, and
    # collapsing the two would report one league's market to the other.
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()

    assert [%{liquidity: 41.0}, %{liquidity: 35.0}] =
             entries |> Enum.filter(&(&1.player_id == 9509)) |> Enum.sort_by(& &1.source)
  end

  test "an expected return is stored as a date, and the bye week travels with it", %{
    bypass: bypass
  } do
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()
    flowers = Enum.filter(entries, &(&1.player_id == 9500))

    # A date rather than KTC's "Aug 22, 2026" string, so a return already in
    # the past can be told from one still ahead.
    assert Enum.all?(flowers, &(&1.injury_return == ~D[2026-08-22]))

    # Per-player, so the same on both format rows — unlike liquidity above.
    assert Enum.all?(flowers, &(&1.bye_week == 11))
  end

  test "a healthy player carries no return date at all", %{bypass: bypass} do
    # `%{"injuryCode" => 1}` is the healthy majority, and it must read as "no
    # date" rather than as a date the parser invented.
    stub(bypass, @players)

    assert {:ok, entries} = KeepTradeCut.fetch_values()
    gibbs = Enum.filter(entries, &(&1.player_id == 9509))

    assert Enum.all?(gibbs, &(&1.injury_return == nil))
    assert Enum.all?(gibbs, &(&1.bye_week == 6))
  end

  test "a return date KTC words differently is dropped, not guessed at", %{bypass: bypass} do
    # Same rule as `parse_pick/1`: a value that does not parse means the feed
    # changed, and that should surface as a missing date rather than a wrong
    # one. "Week 4" and "TBD" are the shapes a date field tends to drift into.
    odd =
      Enum.map(@players, fn p ->
        if p["mflid"] == 16_190,
          do: Map.put(p, "injury", %{"injuryCode" => 2, "injuryReturn" => "Week 4"}),
          else: p
      end)

    stub(bypass, odd)

    assert {:ok, entries} = KeepTradeCut.fetch_values()

    assert entries
           |> Enum.filter(&(&1.player_id == 9500))
           |> Enum.all?(&(&1.injury_return == nil))
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

  test "still reads the older inline playersArray", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(conn, 200, legacy_page(@players))
    end)

    Bypass.stub(bypass, "GET", "/crosswalk.csv", fn conn ->
      Plug.Conn.resp(conn, 200, @crosswalk)
    end)

    assert {:ok, [_ | _]} = KeepTradeCut.fetch_values()
  end

  test "a page that only references the JSON block, without it, is not found", %{bypass: bypass} do
    # What a half-rendered or trimmed page would look like: the script that
    # reads the block is there, the block is not. The inline-literal fallback
    # must not mistake the JSON.parse call for data.
    Bypass.expect_once(bypass, "GET", "/dynasty-rankings", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "<script>var playersArray = JSON.parse(document.getElementById('ktc-players').textContent);</script>"
      )
    end)

    assert {:error, :players_array_not_found} = KeepTradeCut.fetch_values()
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

  describe "TE premium" do
    test "stores each of KTC's three tiers for a tight end, in both formats", %{bypass: bypass} do
      stub(bypass, @players ++ [@tight_end])

      assert {:ok, entries} = KeepTradeCut.fetch_values()

      bowers = entries |> Enum.filter(&(&1.player_id == 11604)) |> Map.new(&{&1.source, &1.value})

      assert bowers == %{
               "keeptradecut:1qb" => 8009.0,
               "keeptradecut:1qb:tep" => 8863.0,
               "keeptradecut:1qb:tepp" => 9700.0,
               "keeptradecut:1qb:teppp" => 9999.0,
               "keeptradecut:sf" => 8040.0,
               "keeptradecut:sf:tep" => 8897.0,
               "keeptradecut:sf:tepp" => 9722.0,
               "keeptradecut:sf:teppp" => 9999.0
             }
    end

    test "stores no tiers for anyone but tight ends", %{bypass: bypass} do
      stub(bypass, @players ++ [@tight_end])

      assert {:ok, entries} = KeepTradeCut.fetch_values()

      refute Enum.any?(entries, &(KeepTradeCut.tep_source?(&1.source) and &1.player_id != 11604))
    end

    test "keeps the tiers out of the value history", %{bypass: bypass} do
      stub(bypass, @players ++ [@tight_end])
      {:ok, entries} = KeepTradeCut.fetch_values()

      SleeperPlayerApi.Intel.record_value_history(entries)

      sources =
        SleeperPlayerApi.Repo.all(SleeperPlayerApi.Intel.PlayerValueHistory)
        |> Enum.map(& &1.source)
        |> Enum.uniq()
        |> Enum.sort()

      assert sources == ["keeptradecut:1qb", "keeptradecut:sf"]
    end
  end

  describe "value bases" do
    # Gibbs as the live payload has him: crowdsourced, trade-based and
    # blended values side by side, in both formats, and a pick likewise.
    defp with_bases(player, sf, oq) do
      player
      |> put_in(["superflexValues"], Map.merge(player["superflexValues"], sf))
      |> put_in(["oneQBValues"], Map.merge(player["oneQBValues"], oq))
    end

    defp players_with_bases do
      [gibbs, flowers, pick] = @players

      [
        with_bases(
          gibbs,
          %{"vftValue" => 9500, "vftRank" => 2, "blendValue" => 9748, "blendRank" => 1},
          %{"vftValue" => 9600, "blendValue" => 9800}
        ),
        flowers,
        with_bases(pick, %{"vftValue" => 5895, "blendValue" => 6492}, %{
          "vftValue" => 6000,
          "blendValue" => 6600
        })
      ]
    end

    test "stores each basis KTC sends, crowdsourced under the plain name", %{bypass: bypass} do
      stub(bypass, players_with_bases())

      assert {:ok, entries} = KeepTradeCut.fetch_values()

      gibbs = entries |> Enum.filter(&(&1.player_id == 9509)) |> Map.new(&{&1.source, &1.value})

      assert gibbs == %{
               "keeptradecut:sf" => 9997.0,
               "keeptradecut:sf:trades" => 9500.0,
               "keeptradecut:sf:blend" => 9748.0,
               "keeptradecut:1qb" => 9999.0,
               "keeptradecut:1qb:trades" => 9600.0,
               "keeptradecut:1qb:blend" => 9800.0
             }

      # A player whose payload has no trade-based figure gets no row for it.
      flowers = entries |> Enum.filter(&(&1.player_id == 9500)) |> Enum.map(& &1.source)
      assert Enum.sort(flowers) == ["keeptradecut:1qb", "keeptradecut:sf"]
    end

    test "prices picks on each basis too", %{bypass: _bypass} do
      picks = KeepTradeCut.pick_entries(players_with_bases(), DateTime.utc_now())

      assert picks |> Enum.map(&{&1.source, &1.value}) |> Enum.sort() == [
               {"keeptradecut:1qb", 7357.0},
               {"keeptradecut:1qb:blend", 6600.0},
               {"keeptradecut:1qb:trades", 6000.0},
               {"keeptradecut:sf", 7080.0},
               {"keeptradecut:sf:blend", 6492.0},
               {"keeptradecut:sf:trades", 5895.0}
             ]
    end

    test "keeps every basis but crowdsourced out of the history", %{bypass: bypass} do
      stub(bypass, players_with_bases())
      {:ok, entries} = KeepTradeCut.fetch_values()

      SleeperPlayerApi.Intel.record_value_history(entries)

      sources =
        SleeperPlayerApi.Repo.all(SleeperPlayerApi.Intel.PlayerValueHistory)
        |> Enum.map(& &1.source)
        |> Enum.uniq()
        |> Enum.sort()

      assert sources == ["keeptradecut:1qb", "keeptradecut:sf"]
    end

    test "the engine reads the configured basis once it is stored, crowdsourced until then" do
      alias SleeperPlayerApi.Intel

      assert Intel.ktc_source("keeptradecut:sf") == "keeptradecut:sf"

      Intel.upsert_player_values([
        %{
          player_id: 9509,
          source: "keeptradecut:sf:blend",
          value: 9748.0,
          overall_rank: 1,
          position_rank: 1,
          as_of: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      assert Intel.ktc_source("keeptradecut:sf") == "keeptradecut:sf:blend"
      # The other format has no blend yet, so it stays crowdsourced.
      assert Intel.ktc_source("keeptradecut:1qb") == "keeptradecut:1qb"
    end
  end
end
