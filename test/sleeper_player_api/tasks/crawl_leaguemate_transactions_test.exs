defmodule SleeperPlayerApi.Tasks.CrawlLeaguemateTransactionsTest do
  # Bypass owns a real port and points the client at it through the shared
  # `:sleeper_base_url` key, so this can't run concurrently with anything
  # else that touches it.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel

  alias SleeperPlayerApi.Intel.{
    ObservedLeague,
    ObservedRoster,
    ObservedRosterHistory,
    ObservedTransaction
  }

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Tasks.CrawlLeaguemateTransactions

  @source_league "555"
  @alice 111
  @bob 222

  setup do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:sleeper_player_api, :sleeper_base_url) end)
    {:ok, bypass: bypass}
  end

  # A transaction in the shape the live endpoint actually returns — verified
  # against `/league/:id/transactions/1` on 2026-08-08, including the detail
  # that `creator` is a user id while `roster_ids` are roster ids.
  defp tx(id, opts) do
    %{
      "transaction_id" => to_string(id),
      "type" => Keyword.get(opts, :type, "free_agent"),
      "status" => Keyword.get(opts, :status, "complete"),
      "created" => Keyword.get(opts, :created, 1_785_000_000_000),
      "creator" => to_string(Keyword.fetch!(opts, :creator)),
      "roster_ids" => Keyword.get(opts, :roster_ids, [1]),
      "consenter_ids" => Keyword.get(opts, :roster_ids, [1]),
      "adds" => Keyword.get(opts, :adds, %{}),
      "drops" => Keyword.get(opts, :drops, %{}),
      "draft_picks" => Keyword.get(opts, :draft_picks, []),
      "settings" => %{"waiver_bid" => Keyword.get(opts, :bid)}
    }
  end

  # `counts` accumulates every path hit, so the "second run makes far fewer
  # calls" checkpoint is observable rather than asserted.
  defp stub(bypass, opts \\ []) do
    weeks = Keyword.get(opts, :week_transactions, %{1 => []})
    leagues_for = Keyword.get(opts, :leagues_for, %{@alice => ["900"], @bob => ["900"]})
    week = Keyword.get(opts, :current_week, 1)
    counts = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/league/#{@source_league}/users", fn conn ->
      :counters.add(counts, 1, 1)

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!([%{"user_id" => "#{@alice}"}, %{"user_id" => "#{@bob}"}])
      )
    end)

    Bypass.stub(bypass, "GET", "/state/nfl", fn conn ->
      :counters.add(counts, 1, 1)
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"week" => week}))
    end)

    for {user, league_ids} <- leagues_for do
      Bypass.stub(bypass, "GET", "/user/#{user}/leagues/nfl/2026", fn conn ->
        :counters.add(counts, 1, 1)
        body = Enum.map(league_ids, &%{"league_id" => &1, "name" => "League #{&1}"})
        Plug.Conn.resp(conn, 200, Jason.encode!(body))
      end)
    end

    # `players` is what per-manager ownership reads. Sleeper sends the ids as
    # strings and omits the key entirely for an unfilled roster, so the
    # default here carries both shapes.
    rosters =
      Keyword.get(opts, :rosters, [
        %{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034", "6794"]},
        %{"roster_id" => 2, "owner_id" => "#{@bob}", "players" => ["4034"]}
      ])

    Bypass.stub(bypass, "GET", "/league/900/rosters", fn conn ->
      :counters.add(counts, 1, 1)
      Plug.Conn.resp(conn, 200, Jason.encode!(rosters))
    end)

    for {w, txs} <- weeks do
      Bypass.stub(bypass, "GET", "/league/900/transactions/#{w}", fn conn ->
        :counters.add(counts, 1, 1)
        Plug.Conn.resp(conn, 200, Jason.encode!(txs))
      end)
    end

    counts
  end

  describe "weeks_to_fetch/2" do
    test "fetches only the current week when everything before it is settled" do
      assert CrawlLeaguemateTransactions.weeks_to_fetch(9, 10) == [10]
    end

    test "backfills everything not yet settled, up to and including the live week" do
      assert CrawlLeaguemateTransactions.weeks_to_fetch(nil, 4) == [1, 2, 3, 4]
      assert CrawlLeaguemateTransactions.weeks_to_fetch(2, 5) == [3, 4, 5]
    end

    test "always refetches the current week, even when marked settled" do
      # This is the offseason case and it is not an edge case: everything
      # lands in week 1 and week 1 never closes, so it must come back every
      # night for months.
      assert CrawlLeaguemateTransactions.weeks_to_fetch(1, 1) == [1]
      assert CrawlLeaguemateTransactions.weeks_to_fetch(5, 1) == [1]
    end
  end

  describe "a cold crawl" do
    test "dedupes the leagues its leaguemates share", %{bypass: bypass} do
      # Two managers, one shared league. The dedupe is the entire argument
      # for crawling over on-demand fetching: 257 real memberships collapse
      # to 176 leagues, and per-profile fetching pays that overlap every time.
      stub(bypass, week_transactions: %{1 => [tx(1, creator: @alice)]})

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert summary.leaguemates == 2
      assert summary.leagues_seen == 1
      assert summary.leagues_fetched == 1
      assert Repo.aggregate(ObservedLeague, :count) == 1
    end

    test "stores transactions with rosters resolved to the users behind them", %{bypass: bypass} do
      # A trade created by alice with bob on the other side. `creator` alone
      # would lose bob, and trades are the rarest and most interesting type.
      stub(bypass,
        week_transactions: %{
          1 => [tx(7, type: "trade", creator: @alice, roster_ids: [1, 2], bid: nil)]
        }
      )

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert summary.transactions_stored == 1

      assert [row] = Repo.all(ObservedTransaction)
      assert row.type == "trade"
      assert row.creator == @alice
      assert row.participant_ids == Enum.sort([@alice, @bob])
      assert row.created == ~U[2026-07-25 17:20:00Z]

      # And it is reachable as the accepting manager's own activity.
      assert [%{id: 7}] = Intel.transactions_for_user(@bob)
    end

    test "keeps failed transactions and waiver bids", %{bypass: bypass} do
      stub(bypass,
        week_transactions: %{
          1 => [tx(8, type: "waiver", status: "failed", creator: @alice, bid: 37)]
        }
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [row] = Repo.all(ObservedTransaction)
      assert row.status == "failed"
      assert row.waiver_bid == 37
    end
  end

  describe "the second run" do
    test "makes far fewer calls, but does refetch the rosters", %{bypass: bypass} do
      # The §3f-style checkpoint for this step. This used to assert the
      # opposite — that a warm run never refetches rosters — which was right
      # while the only thing read out of that payload was `roster_to_user`,
      # a value that cannot change within a season.
      #
      # It now also carries `players`, which changes with every trade, waiver
      # and free-agent add. A cached roster list answers "who did he own the
      # first night we looked", which is worse than no answer because it
      # looks current. Measured cost of the change: ~192 calls to ~346.
      #
      # The saving is now entirely in the settled weeks, so this runs at week
      # 3 rather than week 1: with one league in the offseason there is one
      # live week and nothing else to skip, and a warm run legitimately costs
      # exactly what a cold one does.
      counts =
        stub(bypass,
          current_week: 3,
          week_transactions: %{1 => [tx(1, creator: @alice)], 2 => [], 3 => []}
        )

      assert {:ok, first} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      cold = :counters.get(counts, 1)

      assert {:ok, second} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      warm = :counters.get(counts, 1) - cold

      assert first.rosters_fetched == 1
      assert second.rosters_fetched == 1, "roster contents go stale and must be refetched"
      assert warm < cold, "the week/league dedupe still has to save most of the budget"

      # Re-storing the same live week upserts rather than duplicating.
      assert Repo.aggregate(ObservedTransaction, :count) == 1
    end

    test "still refetches the live week, because the offseason never closes it", %{bypass: bypass} do
      counts = stub(bypass, week_transactions: %{1 => [tx(1, creator: @alice)]})

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      before = :counters.get(counts, 1)
      assert {:ok, second} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert second.weeks_fetched == 1, "week 1 is live and must come back every run"
      assert :counters.get(counts, 1) > before
    end
  end

  describe "roster contents (per-manager ownership)" do
    test "stores who is on each roster, as strings, from the crawl itself", %{bypass: bypass} do
      stub(bypass)
      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      rows = Repo.all(from(r in ObservedRoster, order_by: r.roster_id))

      assert [%{roster_id: 1, owner_id: @alice, player_ids: ["4034", "6794"]}, %{roster_id: 2}] =
               rows

      assert Enum.all?(rows, &(&1.league_id == 900))
      assert Enum.all?(rows, &(&1.fetched_at != nil))
    end

    test "a roster with no players yet stores an empty list, not a null", %{bypass: bypass} do
      stub(bypass,
        rosters: [
          %{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => nil},
          %{"roster_id" => 2, "owner_id" => "#{@bob}"}
        ]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert Repo.all(from(r in ObservedRoster, select: r.player_ids)) == [[], []]
    end

    # The whole point of refetching. A cached list would keep reporting a
    # player his manager has already traded away.
    test "a dropped player stops being owned on the next run", %{bypass: bypass} do
      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034", "6794"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert {%{{@alice, "6794"} => 1}, _} = Intel.ownership(["6794"])

      Bypass.down(bypass)
      bypass = Bypass.open(port: bypass.port)

      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert {ownership, _} = Intel.ownership(["6794"])
      assert ownership == %{}, "ownership must be able to go down as well as up"
    end

    test "a failed roster fetch leaves the previous contents alone", %{bypass: bypass} do
      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      Bypass.down(bypass)
      bypass = Bypass.open(port: bypass.port)
      stub(bypass)
      Bypass.stub(bypass, "GET", "/league/900/rosters", &Plug.Conn.resp(&1, 500, "nope"))

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert [{:rosters_failed, 900, _}] = summary.errors

      assert {%{{@alice, "4034"} => 1}, _} = Intel.ownership(["4034"]),
             "a brief Sleeper failure must read as stale, not as 'nobody owns anybody'"
    end
  end

  describe "roster history (the time series the crawl used to discard)" do
    test "the crawl records each roster's contents against the day it saw them", %{
      bypass: bypass
    } do
      stub(bypass)
      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      rows = Repo.all(from(h in ObservedRosterHistory, order_by: h.roster_id))

      assert [
               %{roster_id: 1, owner_id: @alice, player_ids: ["4034", "6794"], league_id: 900},
               %{roster_id: 2, owner_id: @bob, player_ids: ["4034"], league_id: 900}
             ] = rows

      # The day is the one the observation carries, not whatever the clock
      # said when the row was written.
      assert Enum.all?(rows, &(&1.day == DateTime.to_date(&1.fetched_at)))
    end

    # The entire reason the table exists. `observed_rosters` is overwritten in
    # place, so before this the previous contents were simply gone — and a
    # roster as it stood *then* is the only thing that can validate a read of
    # positional need made at the time.
    test "yesterday's roster survives today's overwrite", %{bypass: bypass} do
      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034", "6794"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      # Age the stored snapshot by a day. The crawl stamps `fetched_at` from
      # the clock, so this is the only way to get two days out of two runs
      # inside one test.
      yesterday = Date.add(Date.utc_today(), -1)

      Repo.update_all(ObservedRosterHistory,
        set: [day: yesterday, fetched_at: DateTime.new!(yesterday, ~T[04:30:00Z])]
      )

      Bypass.down(bypass)
      bypass = Bypass.open(port: bypass.port)

      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [{^yesterday, ["4034", "6794"]}, {_today, ["4034"]}] =
               Repo.all(
                 from(h in ObservedRosterHistory,
                   order_by: h.day,
                   select: {h.day, h.player_ids}
                 )
               )

      assert [%{player_ids: ["4034"]}] = Repo.all(ObservedRoster),
             "the current-snapshot table still holds only the latest"
    end

    test "a second crawl on the same day corrects the day rather than duplicating it", %{
      bypass: bypass
    } do
      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      Bypass.down(bypass)
      bypass = Bypass.open(port: bypass.port)

      stub(bypass,
        rosters: [%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034", "6794"]}]
      )

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [%{player_ids: ["4034", "6794"]}] = Repo.all(ObservedRosterHistory),
             "a day holds one row, and it is that day's close"
    end

    # What makes a point-in-time read of this table sound: a day with no row
    # means "we never looked", so a failed fetch must write nothing.
    #
    # Two leagues, one of which fails, because asserting only that the failing
    # league wrote nothing is over-determined — it stays green when the append
    # is deleted outright (confirmed by sabotage). The league that succeeded
    # has to be in the same run for the assertion to be about the failure.
    test "a failed roster fetch writes no history row, while its neighbour still does", %{
      bypass: bypass
    } do
      stub(bypass, leagues_for: %{@alice => ["900", "901"], @bob => ["900"]})

      Bypass.stub(bypass, "GET", "/league/901/rosters", &Plug.Conn.resp(&1, 500, "nope"))

      Bypass.stub(bypass, "GET", "/league/901/transactions/1", fn conn ->
        Plug.Conn.resp(conn, 200, "[]")
      end)

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert [{:rosters_failed, 901, _}] = summary.errors

      assert [900, 900] =
               Repo.all(
                 from(h in ObservedRosterHistory, select: h.league_id, order_by: h.roster_id)
               )
    end
  end

  # Two rules the crawler cannot reach: it always stamps `fetched_at`, and
  # Sleeper has never been seen to repeat a `roster_id` in one payload.
  describe "append_observed_roster_history/1" do
    setup do
      Intel.upsert_observed_leagues([%{id: 900, season: "2026"}])
      :ok
    end

    # The crawler always hands over `fetched_at == now`, so nothing reachable
    # through it can tell `DateTime.to_date(fetched_at)` apart from
    # `Date.utc_today()`. This is the only test that can.
    test "files a row under the day it was observed, not the day it was written" do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {1, _} =
               Intel.append_observed_roster_history([
                 %{
                   league_id: 900,
                   roster_id: 1,
                   player_ids: ["1"],
                   fetched_at: DateTime.new!(yesterday, ~T[04:30:00Z])
                 }
               ])

      assert [%{day: ^yesterday}] = Repo.all(ObservedRosterHistory)
    end

    test "a row with no fetched_at is dropped rather than dated by guesswork" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {1, _} =
               Intel.append_observed_roster_history([
                 %{
                   league_id: 900,
                   roster_id: 1,
                   owner_id: @alice,
                   player_ids: ["1"],
                   fetched_at: now
                 },
                 %{league_id: 900, roster_id: 2, owner_id: @bob, player_ids: ["2"]}
               ])

      assert [%{roster_id: 1}] = Repo.all(ObservedRosterHistory)
    end

    test "one roster twice in a single call collapses, last one winning" do
      # Postgres refuses an ON CONFLICT DO UPDATE that touches a row twice in
      # one statement, so without the dedupe this does not write twice — it
      # fails the whole batch, taking the rest of the league with it.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      row = fn players ->
        %{league_id: 900, roster_id: 1, player_ids: players, fetched_at: now}
      end

      assert {1, _} = Intel.append_observed_roster_history([row.(["1"]), row.(["1", "2"])])
      assert [%{player_ids: ["1", "2"]}] = Repo.all(ObservedRosterHistory)
    end
  end

  describe "ownership/1" do
    test "counts leagues per manager per player, and gives an honest denominator", %{
      bypass: bypass
    } do
      stub(bypass,
        leagues_for: %{@alice => ["900", "901"], @bob => ["900"]},
        rosters: [
          %{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]},
          %{"roster_id" => 2, "owner_id" => "#{@bob}", "players" => []}
        ]
      )

      # League 901 answers with rosters nobody has filled — the case that
      # made every production figure read 13% low when it was counted.
      Bypass.stub(bypass, "GET", "/league/901/rosters", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!([%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => []}])
        )
      end)

      Bypass.stub(bypass, "GET", "/league/901/transactions/1", &Plug.Conn.resp(&1, 200, "[]"))

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert {ownership, leagues_seen} = Intel.ownership()
      assert ownership == %{{@alice, "4034"} => 1}

      assert leagues_seen == %{@alice => 1},
             "an empty league is one we cannot see into, not one he owns nobody in"
    end

    test "narrowing by player_ids does not narrow the denominators", %{bypass: bypass} do
      stub(bypass)
      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert {ownership, leagues_seen} = Intel.ownership(["6794"])
      assert ownership == %{{@alice, "6794"} => 1}
      assert leagues_seen == %{@alice => 1, @bob => 1}
    end

    test "a league the crawl has stopped refreshing drops out of both sides", %{bypass: bypass} do
      # The production case: the last tracked leaguemate leaves a league, so
      # `/user/:id/leagues` stops listing it and `crawl_league/3` is never
      # called for it again. Nothing deletes its rosters, so without this they
      # keep counting forever, at whatever age they were abandoned.
      stub(bypass, leagues_for: %{@alice => ["900", "901"], @bob => ["900"]})
      stub_extra_league!(bypass, 901)

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert {_, %{@alice => 2}} = Intel.ownership(["4034"])

      age_rosters!(901, 6)

      assert {ownership, leagues_seen} = Intel.ownership(["4034"])

      assert ownership == %{{@alice, "4034"} => 1, {@bob, "4034"} => 1},
             "an abandoned league must leave the numerator"

      assert leagues_seen == %{@alice => 1, @bob => 1},
             "and the denominator with it — never 1 of 2 where the 2 is six days old"
    end

    test "one missed run is stale, not gone", %{bypass: bypass} do
      # The crawl is nightly and a single failed `/league/:id/rosters` is
      # routine. `ensure_roster_map/2` keeps the previous rows on purpose, and
      # this must not undo that a night later.
      stub(bypass, leagues_for: %{@alice => ["900", "901"], @bob => ["900"]})
      stub_extra_league!(bypass, 901)

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      age_rosters!(901, 1)

      assert {_, %{@alice => 2}} = Intel.ownership(["4034"])
    end

    test "a corpus-wide outage excludes nothing", %{bypass: bypass} do
      # Why the cutoff is measured against the freshest row rather than the
      # wall clock. Everything ages together during a Sleeper outage, and an
      # absolute threshold would read that as nobody owning anybody — the
      # read-time version of the failure `ensure_roster_map/2` refuses to
      # write.
      stub(bypass, leagues_for: %{@alice => ["900", "901"], @bob => ["900"]})
      stub_extra_league!(bypass, 901)

      assert {:ok, _} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      age_rosters!(900, 6)
      age_rosters!(901, 6)

      assert {ownership, leagues_seen} = Intel.ownership(["4034"])
      assert ownership == %{{@alice, "4034"} => 2, {@bob, "4034"} => 1}
      assert leagues_seen == %{@alice => 2, @bob => 1}
    end
  end

  # A second league for @alice, so that one can go stale while another stays
  # current. The default `stub/2` only serves league 900.
  defp stub_extra_league!(bypass, league_id) do
    Bypass.stub(bypass, "GET", "/league/#{league_id}/rosters", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!([%{"roster_id" => 1, "owner_id" => "#{@alice}", "players" => ["4034"]}])
      )
    end)

    Bypass.stub(
      bypass,
      "GET",
      "/league/#{league_id}/transactions/1",
      &Plug.Conn.resp(&1, 200, "[]")
    )
  end

  # Backdates a league's rosters as if the crawl had not reached it since.
  defp age_rosters!(league_id, days) do
    then =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(r in ObservedRoster, where: r.league_id == ^league_id),
        set: [fetched_at: then]
      )

    assert count > 0, "nothing to age — the fixture never stored rosters for #{league_id}"
  end

  describe "failure behaviour" do
    test "a league whose rosters fail still stores transactions, attributed to the creator", %{
      bypass: bypass
    } do
      # Partial attribution beats none. Without the roster map a trade's
      # counterparty is unknown, but the creator is still recorded.
      stub(bypass,
        week_transactions: %{1 => [tx(3, type: "trade", creator: @alice, roster_ids: [1, 2])]}
      )

      Bypass.stub(bypass, "GET", "/league/900/rosters", &Plug.Conn.resp(&1, 500, "nope"))

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [{:rosters_failed, 900, _}] = summary.errors
      assert [row] = Repo.all(ObservedTransaction)
      assert row.participant_ids == [@alice]
    end

    test "one leaguemate's enumeration failing does not lose the others", %{bypass: bypass} do
      stub(bypass, week_transactions: %{1 => [tx(1, creator: @bob)]})

      Bypass.stub(
        bypass,
        "GET",
        "/user/#{@alice}/leagues/nfl/2026",
        &Plug.Conn.resp(&1, 500, "nope")
      )

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [{:user_leagues_failed, "111", _}] = summary.errors
      assert summary.leagues_seen == 1, "bob's leagues still made it"
      assert Repo.aggregate(ObservedTransaction, :count) == 1
    end

    test "the member enumeration failing is a hard error, since nothing can proceed", %{
      bypass: bypass
    } do
      Bypass.stub(
        bypass,
        "GET",
        "/league/#{@source_league}/users",
        &Plug.Conn.resp(&1, 500, "nope")
      )

      assert {:error, {:league_users_failed, _}} =
               CrawlLeaguemateTransactions.crawl(@source_league, "2026")
    end

    test "a failing week is recorded without aborting the league", %{bypass: bypass} do
      stub(bypass, week_transactions: %{})

      Bypass.stub(
        bypass,
        "GET",
        "/league/900/transactions/1",
        &Plug.Conn.resp(&1, 429, "slow down")
      )

      assert {:ok, summary} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      assert [{:transactions_failed, 900, 1, {:http_error, 429}}] = summary.errors
      assert summary.leagues_fetched == 1
    end
  end

  describe "in-season week handling" do
    test "backfills past weeks once, then only the live one", %{bypass: bypass} do
      counts =
        stub(bypass,
          current_week: 3,
          week_transactions: %{
            1 => [tx(1, creator: @alice)],
            2 => [tx(2, creator: @alice)],
            3 => [tx(3, creator: @alice)]
          }
        )

      assert {:ok, first} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      assert first.weeks_fetched == 3
      cold = :counters.get(counts, 1)

      assert {:ok, second} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")

      # Weeks 1 and 2 are settled and are never fetched again; week 3 is live.
      # Enumeration (users + state + one call per leaguemate) still runs every
      # pass — the saving is the roster map and the settled weeks, which is
      # where the volume is at 176 leagues.
      assert second.weeks_fetched == 1
      assert :counters.get(counts, 1) - cold < cold
      assert Repo.aggregate(ObservedTransaction, :count) == 3
    end
  end
end
