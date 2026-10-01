defmodule SleeperPlayerApi.Tasks.CrawlMarketDraftsTest do
  # Points the Sleeper client at Bypass through shared Application env.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Market
  alias SleeperPlayerApi.Market.{Draft, Format, Pick, User}
  alias SleeperPlayerApi.Intel.SleeperUser
  alias SleeperPlayerApi.Tasks.CrawlMarketDrafts

  setup do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:sleeper_player_api, :sleeper_base_url) end)
    {:ok, bypass: bypass}
  end

  @now_ms DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  @two_years_ago_ms @now_ms - 2 * 365 * 86_400_000

  defp draft(id, league_id, overrides) do
    Map.merge(
      %{
        "draft_id" => to_string(id),
        "league_id" => to_string(league_id),
        "season" => "2026",
        "status" => "complete",
        "type" => "snake",
        "start_time" => @now_ms - 86_400_000,
        "metadata" => %{"scoring_type" => "dynasty_2qb"},
        "settings" => %{
          "player_type" => 0,
          "teams" => 8,
          "rounds" => 15,
          "slots_qb" => 1,
          "slots_super_flex" => 1
        }
      },
      overrides
    )
  end

  defp picks(teams, rounds) do
    for n <- 1..(teams * rounds) do
      %{
        "pick_no" => n,
        "round" => div(n - 1, teams) + 1,
        "player_id" => "p#{n}",
        "is_keeper" => nil
      }
    end
  end

  defp league(id, type, te_premium) do
    %{
      "league_id" => to_string(id),
      "season" => "2026",
      "total_rosters" => 8,
      "settings" => %{"type" => type},
      "scoring_settings" => %{"rec" => 1.0, "bonus_rec_te" => te_premium}
    }
  end

  defp json(conn, body), do: Plug.Conn.resp(conn, 200, Jason.encode!(body))

  # One seed user whose drafts exercise every rule: a startup in a TE-premium
  # dynasty league (stored), a rookie draft in a keeper league, a redraft,
  # one still drafting, one two years old, and a six-team league.
  defp stub_world(bypass, opts \\ []) do
    startup_picks = Keyword.get(opts, :startup_picks, picks(8, 15))

    routes = %{
      "/user/1/drafts/nfl/2026" => [
        draft(101, 900, %{}),
        draft(102, 901, %{"settings" => %{"player_type" => 1, "teams" => 12, "rounds" => 4}}),
        draft(103, 902, %{"metadata" => %{"scoring_type" => "ppr"}}),
        draft(104, 903, %{"status" => "drafting"}),
        draft(105, 904, %{"start_time" => @two_years_ago_ms}),
        draft(106, 905, %{"settings" => %{"player_type" => 0, "teams" => 6, "rounds" => 20}})
      ],
      "/league/900" => league(900, 2, 0.5),
      "/league/900/users" => [%{"user_id" => "1"}, %{"user_id" => "2"}, %{"user_id" => "3"}],
      "/league/901" => league(901, 1, 0),
      "/league/901/users" => [%{"user_id" => "4"}],
      "/draft/101/picks" => startup_picks,
      "/user/2/drafts/nfl/2026" => [],
      "/user/3/drafts/nfl/2026" => [],
      "/user/4/drafts/nfl/2026" => []
    }

    for {path, body} <- routes, do: Bypass.stub(bypass, "GET", path, &json(&1, body))
  end

  defp seed(user_id), do: Repo.insert!(%SleeperUser{id: user_id, username: "u#{user_id}"})

  test "stores the qualifying draft, counts why the rest were skipped, and snowballs", %{
    bypass: bypass
  } do
    seed(1)
    stub_world(bypass)

    {:ok, summary} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)

    assert [%Draft{id: 101, kind: "startup", qb_slots: 2, te_premium: 0.5, complete: true}] =
             Repo.all(Draft)

    assert Repo.aggregate(Pick, :count) == 120

    assert summary.skipped == %{
             league_not_dynasty: 1,
             not_dynasty: 1,
             not_complete: 1,
             outside_window: 1,
             too_few_teams: 1
           }

    # League 900's users were added one step out; user 4 from the keeper
    # league too, since its users were read along with its format.
    assert Repo.all(from(u in User, order_by: u.id, select: {u.id, u.depth})) ==
             [{1, 0}, {2, 1}, {3, 1}, {4, 1}]

    assert summary.users_crawled == 4
    # 4 users' drafts, 2 leagues and their users, 1 draft's picks.
    assert summary.calls == 9
    assert summary.stopped == :frontier_exhausted
    assert Market.bucket_counts(Format.window_start())[{"startup", "sf", "tep"}] == 1
  end

  test "stops at the budget", %{bypass: bypass} do
    seed(1)
    stub_world(bypass)

    {:ok, summary} = CrawlMarketDrafts.crawl(season: "2026", budget: 2)

    assert summary.calls == 2
    assert summary.stopped == :budget
    assert Repo.all(Draft) == []
  end

  test "a league whose users were cut off by the budget gets them on the next run", %{
    bypass: bypass
  } do
    seed(1)
    stub_world(bypass)

    # 1 call for user 1's drafts, 1 for league 900, then out of budget.
    {:ok, first} = CrawlMarketDrafts.crawl(season: "2026", budget: 2)
    assert first.calls == 2
    assert Repo.aggregate(User, :count) == 1

    Repo.update_all(User, set: [crawled_at: ~U[2026-01-01 00:00:00Z]])
    {:ok, _} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)

    assert Repo.all(from(u in User, order_by: u.id, select: u.id)) == [1, 2, 3, 4]
    assert [%Draft{id: 101}] = Repo.all(Draft)
  end

  test "spends nothing once every bucket is full", %{bypass: bypass} do
    seed(1)
    stub_world(bypass)

    {:ok, summary} = CrawlMarketDrafts.crawl(season: "2026", budget: 100, target_per_bucket: 0)

    assert summary.calls == 0
    assert summary.stopped == :all_buckets_full
  end

  test "keeps a draft with missing picks but does not count it toward its bucket", %{
    bypass: bypass
  } do
    seed(1)
    stub_world(bypass, startup_picks: Enum.take(picks(8, 15), 100))

    {:ok, summary} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)

    assert [%Draft{id: 101, complete: false, picks_count: 100}] = Repo.all(Draft)
    assert summary.drafts_incomplete == 1
    assert Market.bucket_counts(Format.window_start())[{"startup", "sf", "tep"}] == 0
  end

  test "does not reread a user within the revisit window, or refetch a stored draft", %{
    bypass: bypass
  } do
    seed(1)
    stub_world(bypass)
    {:ok, _} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)

    {:ok, again} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)
    assert again.calls == 0
    assert again.stopped == :frontier_exhausted

    # Past the window the user is read again, but the stored draft is not.
    Repo.update_all(User, set: [crawled_at: ~U[2026-01-01 00:00:00Z]])
    {:ok, revisit} = CrawlMarketDrafts.crawl(season: "2026", budget: 100)
    assert revisit.skipped[:already_stored] == 1
    refute Map.has_key?(revisit.skipped, :bucket_full)
  end
end
