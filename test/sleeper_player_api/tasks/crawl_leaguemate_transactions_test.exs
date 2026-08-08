defmodule SleeperPlayerApi.Tasks.CrawlLeaguemateTransactionsTest do
  # Bypass owns a real port and points the client at it through the shared
  # `:sleeper_base_url` key, so this can't run concurrently with anything
  # else that touches it.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.{ObservedLeague, ObservedTransaction}
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

    Bypass.stub(bypass, "GET", "/league/900/rosters", fn conn ->
      :counters.add(counts, 1, 1)

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!([
          %{"roster_id" => 1, "owner_id" => "#{@alice}"},
          %{"roster_id" => 2, "owner_id" => "#{@bob}"}
        ])
      )
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
    test "makes far fewer calls, and does not refetch the roster map", %{bypass: bypass} do
      # The §3f-style checkpoint for this step. Rosters are the saving: which
      # user owns roster N never changes within a season, so refetching 176
      # of them nightly would be most of the budget.
      counts = stub(bypass, week_transactions: %{1 => [tx(1, creator: @alice)]})

      assert {:ok, first} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      cold = :counters.get(counts, 1)

      assert {:ok, second} = CrawlLeaguemateTransactions.crawl(@source_league, "2026")
      warm = :counters.get(counts, 1) - cold

      assert first.rosters_fetched == 1
      assert second.rosters_fetched == 0, "a second run must not refetch a roster map"
      assert warm < cold

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
