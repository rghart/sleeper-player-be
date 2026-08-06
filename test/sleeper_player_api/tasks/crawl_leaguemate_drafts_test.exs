defmodule SleeperPlayerApi.Tasks.CrawlLeaguemateDraftsTest do
  # Bypass owns a real port per test and this module points the client at it
  # via the shared `:sleeper_base_url` Application env key (same trick as
  # `test/clients/sleeper_test.exs`), so this suite can't run concurrently
  # with itself or with anything else that touches that key.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts

  alias SleeperPlayerApi.Intel.{
    DraftParticipant,
    ObservedDraft,
    ObservedPick,
    ObservedTradedPick,
    SleeperUser
  }

  setup do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :sleeper_base_url)
    end)

    {:ok, bypass: bypass}
  end

  # ---------------------------------------------------------------------
  # Fixture builders — small, inline, no corpus dependency
  # ---------------------------------------------------------------------

  defp draft(id, status, opts \\ []) do
    %{
      "draft_id" => id,
      "league_id" => "555",
      "season" => "2026",
      "status" => status,
      "type" => "linear",
      "start_time" => 1_700_000_000_000,
      "settings" => %{
        "player_type" => Keyword.get(opts, :player_type, 1),
        "teams" => 12,
        "rounds" => 4
      }
    }
  end

  defp pick(pick_no, player_id, picked_by, opts \\ []) do
    %{
      "pick_no" => pick_no,
      "round" => Keyword.get(opts, :round, 1),
      "draft_slot" => Keyword.get(opts, :draft_slot, pick_no),
      "roster_id" => Keyword.get(opts, :roster_id, pick_no),
      "player_id" => player_id,
      "picked_by" => picked_by
    }
  end

  defp traded_pick(round, roster_id, previous_owner_id, owner_id) do
    %{
      "season" => "2026",
      "round" => round,
      "roster_id" => roster_id,
      "previous_owner_id" => previous_owner_id,
      "owner_id" => owner_id
    }
  end

  # Registers a JSON-responding expectation and returns an Agent counting
  # how many times it's been hit, so tests can assert call counts (the
  # cold-vs-warm checkpoint needs this) without Bypass's own accounting.
  defp expect_json(bypass, path, body) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "GET", path, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, Jason.encode!(body))
    end)

    counter
  end

  defp expect_status(bypass, path, status) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "GET", path, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, status, "boom")
    end)

    counter
  end

  # Same as `expect_json/3`, but via `Bypass.stub/4` instead of
  # `Bypass.expect/4` — a stub is allowed to be called zero times.
  # `Bypass.expect/4` requires at least one call and fails the test at
  # `on_exit` otherwise, so this is what a test reaches for when it wants
  # to assert a route was *never* hit (a completed draft's
  # `/traded_picks`, per the crawler's deliberate §3c deviation — see the
  # comment on `fetch_traded_picks/3`).
  defp stub_json(bypass, path, body) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "GET", path, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, Jason.encode!(body))
    end)

    counter
  end

  defp hits(counter), do: Agent.get(counter, & &1)

  # ---------------------------------------------------------------------

  describe "cold crawl" do
    test "stores leaguemates, drafts and picks, and never requests traded_picks for a completed draft",
         %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{
          "user_id" => "100",
          "username" => "alice_u",
          "display_name" => "alice",
          "avatar" => "av1"
        }
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1001", "complete")])

      expect_json(bypass, "/draft/1001/picks", [
        pick(1, "P1", "100"),
        pick(2, "P2", nil)
      ])

      # A completed draft's ownership is already fully resolved by
      # `picked_by` on each pick — traded_picks only matters for picks not
      # yet made. The crawler must not call this for a completed draft.
      traded_counter = stub_json(bypass, "/draft/1001/traded_picks", [traded_pick(1, 3, 3, 4)])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.leaguemates == 1
      assert summary.rookie_drafts_seen == 1
      assert summary.drafts_fetched == 1
      assert summary.drafts_skipped == 0
      assert summary.picks_stored == 2
      assert summary.traded_picks_stored == 0
      assert summary.errors == []
      # league/users + user/drafts + picks (no traded_picks for a completed draft)
      assert summary.api_calls == 3
      assert hits(traded_counter) == 0

      assert %SleeperUser{display_name: "alice"} = Repo.get!(SleeperUser, 100)

      assert %ObservedDraft{status: "complete", picks_fetched_at: fetched_at} =
               Repo.get!(ObservedDraft, 1001)

      refute is_nil(fetched_at)

      picks = Repo.all(from(p in ObservedPick, where: p.draft_id == 1001, order_by: p.pick_no))
      assert [%{player_id: "P1", picked_by: 100}, %{player_id: "P2", picked_by: nil}] = picks

      assert Repo.all(from(t in ObservedTradedPick, where: t.draft_id == 1001)) == []
    end
  end

  describe "the immutability checkpoint" do
    test "a second crawl over an already-complete draft makes no further picks/traded_picks calls",
         %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      user_drafts_counter =
        expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1001", "complete")])

      picks_counter = expect_json(bypass, "/draft/1001/picks", [pick(1, "P1", "100")])
      # Completed draft — traded_picks must never be requested at all (see
      # the "cold crawl" test above), not just "not requested again".
      traded_counter = stub_json(bypass, "/draft/1001/traded_picks", [])

      assert {:ok, first} = CrawlLeaguemateDrafts.crawl(555, "2026")
      assert first.drafts_fetched == 1
      assert hits(picks_counter) == 1
      assert hits(traded_counter) == 0

      assert {:ok, second} = CrawlLeaguemateDrafts.crawl(555, "2026")

      # The property that matters: no further picks calls, and still no
      # traded_picks calls at all.
      assert hits(picks_counter) == 1
      assert hits(traded_counter) == 0
      assert second.drafts_fetched == 0
      assert second.drafts_skipped == 1

      # Enumeration itself is cheap and always repeats — that's expected,
      # it's the picks/traded_picks calls that must not repeat.
      assert hits(user_drafts_counter) == 2
    end
  end

  describe "a draft still drafting" do
    test "is refetched on every crawl", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1002", "drafting")])

      picks_counter = expect_json(bypass, "/draft/1002/picks", [pick(1, "P1", "100")])
      traded_counter = expect_json(bypass, "/draft/1002/traded_picks", [])

      assert {:ok, _} = CrawlLeaguemateDrafts.crawl(555, "2026")
      assert {:ok, second} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert hits(picks_counter) == 2
      assert hits(traded_counter) == 2
      assert second.drafts_fetched == 1
      assert second.drafts_skipped == 0
    end

    test "DOES fetch and store /traded_picks, unlike a completed draft", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1002", "drafting")])

      expect_json(bypass, "/draft/1002/picks", [pick(1, "P1", "100")])
      traded_counter = expect_json(bypass, "/draft/1002/traded_picks", [traded_pick(1, 3, 3, 4)])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      # This is the regression guard: an in-progress draft's picks aren't
      # fully resolved yet, so traded_picks is the case that actually
      # needs the call — it must not get "simplified" away along with the
      # completed-draft skip.
      assert hits(traded_counter) == 1
      assert summary.traded_picks_stored == 1

      assert [%ObservedTradedPick{previous_owner_id: 3, owner_id: 4}] =
               Repo.all(from(t in ObservedTradedPick, where: t.draft_id == 1002))
    end
  end

  describe "a pre_draft draft" do
    test "never triggers a picks call, but its row is still kept", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1003", "pre_draft")])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.drafts_fetched == 0
      assert summary.drafts_skipped == 1
      assert summary.api_calls == 2

      assert %ObservedDraft{status: "pre_draft", picks_fetched_at: nil} =
               Repo.get!(ObservedDraft, 1003)

      assert Repo.all(from(p in ObservedPick, where: p.draft_id == 1003)) == []
    end
  end

  describe "error handling" do
    test "one draft 500ing on /picks doesn't abort the crawl of the others", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [
        draft("1001", "complete"),
        draft("1005", "complete")
      ])

      expect_json(bypass, "/draft/1001/picks", [pick(1, "P1", "100")])
      # Both drafts are "complete", so traded_picks is never requested for
      # either — the picks failure on 1005 doesn't change that (the skip
      # is decided by status, before the picks result is even known).
      traded_counter_1001 = stub_json(bypass, "/draft/1001/traded_picks", [])

      expect_status(bypass, "/draft/1005/picks", 500)
      traded_counter_1005 = stub_json(bypass, "/draft/1005/traded_picks", [])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.drafts_fetched == 2
      assert summary.traded_picks_stored == 0
      assert hits(traded_counter_1001) == 0
      assert hits(traded_counter_1005) == 0
      assert [{:picks, 1005, {:http_error, 500}}] = summary.errors

      # The good draft's picks made it in.
      assert [%{player_id: "P1"}] = Repo.all(from(p in ObservedPick, where: p.draft_id == 1001))

      # The failed draft stored no picks, and isn't marked as fetched, so
      # a later crawl will retry it rather than treating it as done.
      assert Repo.all(from(p in ObservedPick, where: p.draft_id == 1005)) == []
      assert %ObservedDraft{picks_fetched_at: nil} = Repo.get!(ObservedDraft, 1005)
    end
  end

  describe "crawl_configured_leagues/0 — the scheduled entry point" do
    setup do
      on_exit(fn ->
        Application.delete_env(:sleeper_player_api, :intel_leagues)
        Application.delete_env(:sleeper_player_api, :intel_season)
      end)

      :ok
    end

    test "does nothing, quietly, when no leagues are configured" do
      Application.put_env(:sleeper_player_api, :intel_leagues, [])
      assert CrawlLeaguemateDrafts.crawl_configured_leagues() == []
    end

    test "defaults the season to the current calendar year", %{bypass: bypass} do
      year = Date.utc_today().year |> Integer.to_string()
      Application.put_env(:sleeper_player_api, :intel_leagues, [555])

      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      # If the season were wrong this path would never be requested and
      # Bypass would fail the test on an unrequested expectation.
      expect_json(bypass, "/user/100/drafts/nfl/#{year}", [])

      assert [{555, {:ok, _summary}}] = CrawlLeaguemateDrafts.crawl_configured_leagues()
    end

    test "an explicit :intel_season overrides the default", %{bypass: bypass} do
      Application.put_env(:sleeper_player_api, :intel_leagues, [555])
      Application.put_env(:sleeper_player_api, :intel_season, "2019")

      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2019", [])

      assert [{555, {:ok, _}}] = CrawlLeaguemateDrafts.crawl_configured_leagues()
    end

    test "one league failing doesn't stop the others", %{bypass: bypass} do
      Application.put_env(:sleeper_player_api, :intel_leagues, [555, 666])
      Application.put_env(:sleeper_player_api, :intel_season, "2026")

      # 555 can't even be enumerated.
      Bypass.expect(bypass, "GET", "/league/555/users", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
      end)

      expect_json(bypass, "/league/666/users", [
        %{"user_id" => "200", "display_name" => "bob", "avatar" => "av2"}
      ])

      expect_json(bypass, "/user/200/drafts/nfl/2026", [draft("1001", "complete")])
      expect_json(bypass, "/draft/1001/picks", [pick(1, "P1", "200")])

      results = CrawlLeaguemateDrafts.crawl_configured_leagues()

      assert [{555, {:error, _}}, {666, {:ok, summary}}] = results
      assert summary.picks_stored == 1

      # The healthy league's data really landed, despite the first one dying.
      assert %ObservedDraft{} = Repo.get(ObservedDraft, 1001)
    end
  end

  describe "picks Sleeper can't attribute to a user" do
    # Regression: a live production crawl died on the first draft it hit.
    # Real Sleeper data uses `picked_by: ""` (not null) for an autopicked or
    # otherwise unattributed pick — 3 of the 3,286 picks in the harvested
    # corpus are like this. `String.to_integer("")` raises, and it took the
    # whole crawl down.
    #
    # This never surfaced because every other test either used a real id or
    # nil, and the DB-seeding test helpers parse `picked_by` themselves
    # rather than going through the crawler.
    test "an empty-string picked_by is stored as nil, not a crash", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1001", "complete")])

      expect_json(bypass, "/draft/1001/picks", [
        pick(1, "P1", "100"),
        pick(2, "P2", ""),
        pick(3, "P3", nil)
      ])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.errors == []
      assert summary.picks_stored == 3

      picks = Repo.all(from(p in ObservedPick, where: p.draft_id == 1001, order_by: p.pick_no))

      assert [
               %{player_id: "P1", picked_by: 100},
               %{player_id: "P2", picked_by: nil},
               %{player_id: "P3", picked_by: nil}
             ] = picks
    end
  end

  describe "rookie filtering" do
    test "only rookie drafts (settings.player_type == 1) are crawled or stored", %{
      bypass: bypass
    } do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [
        draft("1001", "complete", player_type: 1),
        draft("1004", "complete", player_type: 0)
      ])

      expect_json(bypass, "/draft/1001/picks", [pick(1, "P1", "100")])
      # 1001 is complete, so no traded_picks call for it either.
      traded_counter = stub_json(bypass, "/draft/1001/traded_picks", [])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.drafts_seen == 2
      assert summary.rookie_drafts_seen == 1
      assert summary.drafts_fetched == 1
      assert hits(traded_counter) == 0

      assert Repo.get(ObservedDraft, 1001) != nil
      assert Repo.get(ObservedDraft, 1004) == nil
    end
  end

  describe "call-count arithmetic (§3f step 3's actual checkpoint)" do
    test "2 leaguemates and 3 unique completed rookie drafts cost exactly 1 + 2 + 3 = 6 calls",
         %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"},
        %{"user_id" => "200", "display_name" => "bob", "avatar" => "av2"}
      ])

      d1 = draft("2001", "complete")
      d2 = draft("2002", "complete")
      d3 = draft("2003", "complete")

      # d2 is shared — it must be deduped, not fetched twice.
      expect_json(bypass, "/user/100/drafts/nfl/2026", [d1, d2])
      expect_json(bypass, "/user/200/drafts/nfl/2026", [d2, d3])

      expect_json(bypass, "/draft/2001/picks", [pick(1, "P1", "100")])
      expect_json(bypass, "/draft/2002/picks", [pick(1, "P2", "100")])
      expect_json(bypass, "/draft/2003/picks", [pick(1, "P3", "200")])

      # None of these three get a traded_picks call — they're all complete.
      t1 = stub_json(bypass, "/draft/2001/traded_picks", [])
      t2 = stub_json(bypass, "/draft/2002/traded_picks", [])
      t3 = stub_json(bypass, "/draft/2003/traded_picks", [])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert summary.leaguemates == 2
      assert summary.drafts_seen == 3
      assert summary.rookie_drafts_seen == 3
      assert summary.drafts_fetched == 3
      assert summary.picks_stored == 3
      assert summary.traded_picks_stored == 0

      # 1 (league/users) + 2 (user/drafts, one per leaguemate) + 3 (picks,
      # one per unique draft) — no traded_picks calls at all.
      assert summary.api_calls == 6
      assert Enum.map([t1, t2, t3], &hits/1) == [0, 0, 0]
    end
  end

  describe "draft_participants (Gap 1: populated by a real crawl, not seeded)" do
    # Regression per the report on this step: `draft_participants` existed
    # with a passing unit test on `Intel.upsert_draft_participants/2`
    # directly, but nothing in the crawl path called it, so production had
    # 0 rows. These tests drive the real `crawl/2` against Bypass — no
    # DB-seeding helper in the path — and assert on the table and the
    # participation query it feeds, per
    # `tests-that-bypass-the-crawler` lessons.
    test "a crawled draft's distinct pickers land in draft_participants, and manager_drafts_seen counts them",
         %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"},
        %{"user_id" => "200", "display_name" => "bob", "avatar" => "av2"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1001", "complete")])
      expect_json(bypass, "/user/200/drafts/nfl/2026", [draft("1001", "complete")])

      # alice picks twice, bob once, one pick unattributed (nil) — draft
      # participation must be distinct pickers, not distinct picks.
      expect_json(bypass, "/draft/1001/picks", [
        pick(1, "P1", "100"),
        pick(2, "P2", "200"),
        pick(3, "P3", "100"),
        pick(4, "P4", nil)
      ])

      stub_json(bypass, "/draft/1001/traded_picks", [])

      assert {:ok, _summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      rows =
        Repo.all(from(dp in DraftParticipant, where: dp.draft_id == 1001, order_by: dp.user_id))

      assert Enum.map(rows, & &1.user_id) == [100, 200]

      seen = Intel.manager_drafts_seen()
      assert Map.get(seen, 100) == 1
      assert Map.get(seen, 200) == 1
    end

    test "a picker who isn't one of this league's own leaguemates still gets a participant row (no FK crash)",
         %{bypass: bypass} do
      # alice's OTHER league draft is full of co-managers `sleeper_users`
      # never heard of via `/league/555/users` — draft_participants must not
      # have a hard FK to sleeper_users (see
      # `20260806140000_drop_draft_participants_user_fk.exs`) or this raises.
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1001", "complete")])

      expect_json(bypass, "/draft/1001/picks", [
        pick(1, "P1", "100"),
        pick(2, "P2", "999")
      ])

      stub_json(bypass, "/draft/1001/traded_picks", [])

      assert {:ok, summary} = CrawlLeaguemateDrafts.crawl(555, "2026")
      assert summary.errors == []

      rows =
        Repo.all(from(dp in DraftParticipant, where: dp.draft_id == 1001, order_by: dp.user_id))

      assert Enum.map(rows, & &1.user_id) == [100, 999]
      refute Repo.get(SleeperUser, 999)
    end

    test "a pre_draft draft (no picks fetched) gets no participant rows", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1003", "pre_draft")])

      assert {:ok, _summary} = CrawlLeaguemateDrafts.crawl(555, "2026")

      assert Repo.all(from(dp in DraftParticipant, where: dp.draft_id == 1003)) == []
    end

    test "re-crawling an in-progress draft doesn't duplicate participant rows", %{bypass: bypass} do
      expect_json(bypass, "/league/555/users", [
        %{"user_id" => "100", "display_name" => "alice", "avatar" => "av1"}
      ])

      expect_json(bypass, "/user/100/drafts/nfl/2026", [draft("1002", "drafting")])
      expect_json(bypass, "/draft/1002/picks", [pick(1, "P1", "100")])
      expect_json(bypass, "/draft/1002/traded_picks", [])

      assert {:ok, _} = CrawlLeaguemateDrafts.crawl(555, "2026")
      assert {:ok, _} = CrawlLeaguemateDrafts.crawl(555, "2026")

      rows = Repo.all(from(dp in DraftParticipant, where: dp.draft_id == 1002))
      assert length(rows) == 1
    end
  end
end
