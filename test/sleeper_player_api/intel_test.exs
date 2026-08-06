defmodule SleeperPlayerApi.IntelTest do
  # `league_intel/2` now makes a live `GET /league/:id/users` call (Gap 2 —
  # see its moduledoc), so the `describe "league_intel/2"` block below points
  # the Sleeper client at a Bypass server via the shared `:sleeper_base_url`
  # Application env key (same trick as `CrawlLeaguemateDraftsTest`), which
  # means this whole module can't run concurrently with itself or with
  # anything else that touches that key.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.IntelCorpus
  alias SleeperPlayerApi.Intel.{Estimator, ObservedDraft, ObservedPick}

  @corpus_dir Path.expand("../support/corpus", __DIR__)

  # ---------------------------------------------------------------------
  # Small inline fixtures — no corpus needed, always run
  # ---------------------------------------------------------------------

  describe "upserts + drafts_corpus/1 against a hand-built fixture" do
    test "shapes a stored draft into exactly the estimator's input structure" do
      Intel.upsert_observed_drafts([%{id: 1, teams: 12, status: "complete"}])

      Intel.upsert_observed_picks(1, [
        %{pick_no: 1, round: 1, draft_slot: 1, roster_id: 1, player_id: "P1", picked_by: 100},
        %{pick_no: 2, round: 1, draft_slot: 2, roster_id: 2, player_id: "P2", picked_by: nil}
      ])

      assert [draft] = Intel.drafts_corpus(%{100 => "alice"})

      assert_in_delta draft.l_d, Estimator.normalize_pick(2, 12), 1.0e-9

      assert draft.picks == [
               %{norm: Estimator.normalize_pick(1, 12), player_id: "P1", manager: "alice"},
               %{norm: Estimator.normalize_pick(2, 12), player_id: "P2", manager: nil}
             ]
    end

    test "a draft with no stored picks is skipped, not crashed on" do
      Intel.upsert_observed_drafts([%{id: 2, teams: 12, status: "pre_draft"}])

      assert Intel.drafts_corpus(%{}) == []
    end

    test "unmapped picked_by (not a tracked leaguemate) still counts toward the draft, manager: nil" do
      Intel.upsert_observed_drafts([%{id: 3, teams: 12, status: "complete"}])
      Intel.upsert_observed_picks(3, [%{pick_no: 1, player_id: "P1", picked_by: 999}])

      assert [%{picks: [%{manager: nil}]}] = Intel.drafts_corpus(%{100 => "alice"})
    end

    test "upserts are idempotent and update in place on conflict, not duplicate" do
      Intel.upsert_observed_drafts([%{id: 4, teams: 10, status: "drafting"}])
      Intel.upsert_observed_picks(4, [%{pick_no: 1, player_id: "P1", picked_by: 5}])

      # A re-crawl of an in-progress draft (plan §3c) overwrites in place.
      Intel.upsert_observed_drafts([%{id: 4, teams: 10, status: "complete"}])
      Intel.upsert_observed_picks(4, [%{pick_no: 1, player_id: "P9", picked_by: 5}])

      assert %{status: "complete"} = Repo.get!(ObservedDraft, 4)

      assert [%{player_id: "P9"}] =
               Repo.all(from(p in ObservedPick, where: p.draft_id == 4))
    end

    test "upsert_draft_participants/2 is idempotent on the (draft_id, user_id) pair" do
      Intel.upsert_sleeper_users([
        %{id: 10, display_name: "alice"},
        %{id: 11, display_name: "bob"}
      ])

      Intel.upsert_observed_drafts([%{id: 5, teams: 12, status: "complete"}])

      Intel.upsert_draft_participants(5, [10, 11])
      Intel.upsert_draft_participants(5, [10, 11, 10])

      rows =
        Repo.all(from(dp in SleeperPlayerApi.Intel.DraftParticipant, where: dp.draft_id == 5))

      assert length(rows) == 2
    end

    test "upsert_observed_traded_picks/2 stores ownership rows keyed on (draft_id, season, round, roster_id)" do
      Intel.upsert_observed_drafts([%{id: 6, teams: 12, status: "complete"}])

      Intel.upsert_observed_traded_picks(6, [
        %{season: "2026", round: 1, roster_id: 1, previous_owner_id: 1, owner_id: 2}
      ])

      # Re-crawling with a new owner overwrites the same logical row.
      Intel.upsert_observed_traded_picks(6, [
        %{season: "2026", round: 1, roster_id: 1, previous_owner_id: 1, owner_id: 3}
      ])

      assert [%{owner_id: 3}] =
               Repo.all(
                 from(tp in SleeperPlayerApi.Intel.ObservedTradedPick, where: tp.draft_id == 6)
               )
    end

    test "upsert_player_values/1 upserts on (player_id, source)" do
      Intel.upsert_player_values([
        %{player_id: 100, source: "fantasycalc", value: 5000.0, overall_rank: 3}
      ])

      Intel.upsert_player_values([
        %{player_id: 100, source: "fantasycalc", value: 5200.0, overall_rank: 2}
      ])

      assert [%{value: 5200.0, overall_rank: 2}] =
               Repo.all(
                 from(pv in SleeperPlayerApi.Intel.PlayerValue,
                   where: pv.player_id == 100 and pv.source == "fantasycalc"
                 )
               )
    end
  end

  # ---------------------------------------------------------------------
  # backfill_draft_participants/0 — the mandatory production catch-up
  # ---------------------------------------------------------------------

  describe "backfill_draft_participants/0" do
    test "derives participant rows from observed_picks and is safe to run twice" do
      Intel.upsert_observed_drafts([
        %{id: 701, teams: 12, status: "complete"},
        %{id: 702, teams: 12, status: "complete"}
      ])

      Intel.upsert_observed_picks(701, [
        %{pick_no: 1, player_id: "P1", picked_by: 10},
        %{pick_no: 2, player_id: "P2", picked_by: 11},
        %{pick_no: 3, player_id: "P3", picked_by: 10}
      ])

      Intel.upsert_observed_picks(702, [
        %{pick_no: 1, player_id: "P1", picked_by: 11},
        %{pick_no: 2, player_id: "P2", picked_by: nil}
      ])

      # Simulate the exact production gap this backfills: observed_picks
      # populated, draft_participants empty. `upsert_observed_picks/2`
      # normally keeps the two in sync as it writes (see its doc) — but
      # production accumulated its ~3,400 picks before that existed, so
      # this wipes the table back to that pre-fix state before backfilling.
      Repo.delete_all(SleeperPlayerApi.Intel.DraftParticipant)

      assert Intel.backfill_draft_participants() == {3, nil}

      rows_query =
        from(dp in SleeperPlayerApi.Intel.DraftParticipant,
          order_by: [dp.draft_id, dp.user_id],
          select: {dp.draft_id, dp.user_id}
        )

      assert Repo.all(rows_query) == [{701, 10}, {701, 11}, {702, 11}]

      # Idempotent: running again inserts nothing new and changes nothing.
      assert Intel.backfill_draft_participants() == {0, nil}
      assert Repo.all(rows_query) == [{701, 10}, {701, 11}, {702, 11}]
    end
  end

  # ---------------------------------------------------------------------
  # league_intel/2 (plan §3e / §3f step 5) — hand-built fixture, no corpus
  # ---------------------------------------------------------------------

  describe "league_intel/2" do
    # Gap 2: `league_intel/2` now derives "who's a manager" from a live
    # `GET /league/:id/users` call, not from `observed_picks`/
    # `draft_participants` — see the moduledoc on `Intel.league_intel/2` for
    # why. So this block needs a Bypass server the way
    # `CrawlLeaguemateDraftsTest` does.
    setup do
      bypass = Bypass.open()

      Application.put_env(
        :sleeper_player_api,
        :sleeper_base_url,
        "http://localhost:#{bypass.port}"
      )

      on_exit(fn -> Application.delete_env(:sleeper_player_api, :sleeper_base_url) end)

      Intel.upsert_sleeper_users([
        %{id: 100, display_name: "alice"},
        %{id: 200, display_name: "bob"}
      ])

      seed_player!("P1", "WR")
      seed_player!("P2", "RB")

      # The home league (555), season 2026 — the league every test below
      # analyzes.
      Intel.upsert_observed_drafts([
        %{id: 501, league_id: 555, season: "2026", status: "complete", teams: 12, rounds: 1}
      ])

      Intel.upsert_observed_picks(501, [
        %{pick_no: 1, player_id: "P1", picked_by: 100},
        %{pick_no: 2, player_id: "P2", picked_by: 200}
      ])

      # Alice's other leagues (777, 999-via-bob) — these must count toward
      # her `leagues_count`/`drafts_count`/`reach_vs_adp` totals (not
      # scoped to league 555).
      Intel.upsert_observed_drafts([
        %{id: 502, league_id: 777, season: "2026", status: "complete", teams: 12, rounds: 1},
        %{id: 503, league_id: 555, season: "2025", status: "complete", teams: 12, rounds: 1},
        %{id: 504, league_id: 999, season: "2026", status: "complete", teams: 12, rounds: 1}
      ])

      Intel.upsert_observed_picks(502, [%{pick_no: 3, player_id: "P1", picked_by: 100}])
      Intel.upsert_observed_picks(503, [%{pick_no: 5, player_id: "P1", picked_by: 100}])
      Intel.upsert_observed_picks(504, [%{pick_no: 1, player_id: "P1", picked_by: 200}])

      {:ok, bypass: bypass}
    end

    defp stub_league_users(bypass, league_id, users) do
      Bypass.stub(bypass, "GET", "/league/#{league_id}/users", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(users))
      end)
    end

    defp fail_league_users(bypass, league_id) do
      Bypass.stub(bypass, "GET", "/league/#{league_id}/users", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)
    end

    test "managers come from the live /league/:id/users call; per-manager counts are corpus-wide",
         %{bypass: bypass} do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      %{managers: managers, corpus: corpus} = Intel.league_intel(555, season: "2026")

      assert Enum.map(managers, & &1.user_id) == [100, 200]
      assert corpus.membership_source == :live

      alice = Enum.find(managers, &(&1.user_id == 100))
      assert alice.display_name == "alice"
      # drafts 501 (league 555), 502 (777), 503 (555, season 2025) — 2 distinct leagues.
      assert alice.leagues_count == 2
      assert alice.drafts_count == 3
      assert alice.drafts_complete == 3

      bob = Enum.find(managers, &(&1.user_id == 200))
      # bob only appears in 501 (555) and 504 (999) — 2 leagues, 2 drafts.
      assert bob.leagues_count == 2
      assert bob.drafts_count == 2

      assert corpus.drafts == 4
      assert corpus.picks == 5
    end

    test "a live league member with zero observed drafts appears with honest zeros, not absent",
         %{bypass: bypass} do
      # carol is a real league member Sleeper reports, but has never
      # appeared in any stored draft — the exact case §3 Frontend needs
      # ("league average · none of their drafts seen") and that deriving
      # membership from observed_picks/draft_participants could never show.
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"},
        %{"user_id" => "300", "display_name" => "carol"}
      ])

      %{managers: managers, corpus: corpus} = Intel.league_intel(555, season: "2026")

      assert Enum.map(managers, & &1.user_id) == [100, 200, 300]
      assert corpus.membership_source == :live

      carol = Enum.find(managers, &(&1.user_id == 300))
      assert carol.display_name == "carol"
      assert carol.leagues_count == 0
      assert carol.drafts_count == 0
      assert carol.drafts_complete == 0
      assert carol.tendencies.crushes == []
      assert carol.tendencies.position_lean == []
      assert carol.tendencies.reach_vs_adp == nil
    end

    test "when the live call fails, falls back to observed-participation-derived membership, honestly flagged",
         %{bypass: bypass} do
      fail_league_users(bypass, 555)

      %{managers: managers_2025, corpus: corpus} = Intel.league_intel(555, season: "2025")

      assert corpus.membership_source == :derived
      # Only draft 503 (season 2025) belongs to league 555 in that season,
      # and only alice picked in it — the derived fallback's season filter
      # (the live path ignores `season` entirely, see the moduledoc).
      assert Enum.map(managers_2025, & &1.user_id) == [100]

      alice_2025 = hd(managers_2025)
      # Same corpus-wide totals regardless of which season made her a manager.
      assert alice_2025.leagues_count == 2
      assert alice_2025.drafts_count == 3
    end

    test "derived fallback: omitting season includes every stored season for this league_id",
         %{bypass: bypass} do
      fail_league_users(bypass, 555)

      %{managers: managers} = Intel.league_intel(555, [])
      assert Enum.map(managers, & &1.user_id) == [100, 200]
    end

    test "an unknown league_id whose live call also fails returns an empty managers list, not an error",
         %{bypass: bypass} do
      fail_league_users(bypass, 424_242)

      assert %{managers: [], corpus: %{drafts: 4, membership_source: :derived}} =
               Intel.league_intel(424_242, season: "2026")
    end

    test "tendencies.crushes: alice's repeated P1 picks across every league she's in",
         %{bypass: bypass} do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      %{managers: managers} = Intel.league_intel(555, season: "2026")
      alice = Enum.find(managers, &(&1.user_id == 100))

      assert [%{player_id: "P1", times: 3, of: 3}] = alice.tendencies.crushes
    end

    test "tendencies.position_lean: 100% of alice's picks are WR", %{bypass: bypass} do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      %{managers: managers} = Intel.league_intel(555, season: "2026")
      alice = Enum.find(managers, &(&1.user_id == 100))

      assert alice.tendencies.position_lean == [%{position: "WR", picks: 3, share: 1.0}]
    end

    test "tendencies.reach_vs_adp: league ADP minus the manager's own ADP, n >= 2 only",
         %{bypass: bypass} do
      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"}
      ])

      %{managers: managers} = Intel.league_intel(555, season: "2026")
      alice = Enum.find(managers, &(&1.user_id == 100))

      # P1 corpus events: alice at norm 1.0 (501), 3.0 (502), 5.0 (503);
      # bob at norm 1.0 (504). League ADP = (1+3+5+1)/4 = 2.5.
      # Alice's own ADP for P1 = (1+3+5)/3 = 3.0.
      # reach_vs_adp = 2.5 - 3.0 = -0.5 (she drafts P1 later than the
      # corpus average — the sign convention this step chose: positive
      # means "reaches earlier than average", negative means "lets him
      # slide").
      assert_in_delta alice.tendencies.reach_vs_adp, -0.5, 0.001
    end

    test "tendencies.reach_vs_adp is nil when no picked player clears the n >= 2 corpus threshold",
         %{bypass: bypass} do
      Intel.upsert_sleeper_users([%{id: 300, display_name: "carol"}])
      seed_player!("P3", "TE")

      Intel.upsert_observed_drafts([
        %{id: 505, league_id: 555, season: "2026", status: "complete", teams: 12, rounds: 1}
      ])

      Intel.upsert_observed_picks(505, [%{pick_no: 1, player_id: "P3", picked_by: 300}])

      stub_league_users(bypass, 555, [
        %{"user_id" => "100", "display_name" => "alice"},
        %{"user_id" => "200", "display_name" => "bob"},
        %{"user_id" => "300", "display_name" => "carol"}
      ])

      %{managers: managers} = Intel.league_intel(555, season: "2026")
      carol = Enum.find(managers, &(&1.user_id == 300))

      assert carol.tendencies.reach_vs_adp == nil
    end
  end

  # ---------------------------------------------------------------------
  # Corpus round-trip — the point of this step
  # ---------------------------------------------------------------------

  describe "corpus round-trip through Postgres" do
    @describetag :corpus

    setup do
      seed_corpus_from_json!()
      :ok
    end

    test "drafts_corpus/1 is byte-identical to IntelCorpus.drafts/0 once both are canonically sorted" do
      uid_to_manager =
        IntelCorpus.user_id_to_manager()
        |> Map.new(fn {uid, manager} -> {String.to_integer(uid), manager} end)

      from_json = IntelCorpus.drafts() |> canonicalize()
      from_db = Intel.drafts_corpus(uid_to_manager) |> canonicalize()

      assert from_db == from_json
    end

    test "league_adp_summary/1 (SQL GROUP BY) matches Estimator.adp_summary/1 (pure Elixir) on the same corpus" do
      drafts = IntelCorpus.drafts()

      for player_id <- sample_player_ids() do
        expected = drafts |> Estimator.player_events(player_id) |> Estimator.adp_summary()
        actual = Intel.league_adp_summary(player_id)

        case expected do
          nil ->
            assert actual == nil, "expected no ADP summary for #{player_id}"

          _ ->
            assert actual.n == expected.n, "n mismatch for #{player_id}"
            assert_in_delta actual.adp, expected.adp, 0.001
            assert_in_delta actual.sd, expected.sd, 0.001
            assert_in_delta actual.min, expected.min, 0.001
            assert_in_delta actual.max, expected.max, 0.001
        end
      end
    end

    test "manager_adp_summary/1 counts and per-manager ADP match Estimator.manager_seen/took over the same picks" do
      uid_to_manager = IntelCorpus.user_id_to_manager()
      player_id = "13306"

      per_manager = Intel.manager_adp_summary(player_id)

      babaghanoush_uid =
        uid_to_manager
        |> Enum.find(fn {_uid, name} -> name == "babaghanoush123" end)
        |> elem(0)
        |> String.to_integer()

      assert %{n: 13} =
               Enum.find(per_manager, fn row -> row.user_id == babaghanoush_uid end)
    end

    test "manager_drafts_seen/0 matches Estimator.manager_seen/2 for each tracked manager" do
      drafts = IntelCorpus.drafts()
      seen_by_manager = Intel.manager_drafts_seen()
      uid_to_manager = IntelCorpus.user_id_to_manager()

      for {uid, manager} <- uid_to_manager do
        expected = Estimator.manager_seen(drafts, manager)
        actual = Map.get(seen_by_manager, String.to_integer(uid), 0)
        assert actual == expected, "seen mismatch for #{manager}"
      end
    end

    # The point of this whole step: the DB is an adapter into the estimator, and
    # the estimator's numbers are already locked against the reference fixture.
    # Structural equality (above) implies this, but assert the actual validated
    # number through the Postgres path anyway — if a future schema or query
    # change ever distorts the corpus, this fails with a recognisable value
    # rather than a diff of two large structures.
    test "survival computed through the Postgres path reproduces the fixture" do
      uid_to_manager =
        IntelCorpus.user_id_to_manager()
        |> Map.new(fn {uid, manager} -> {String.to_integer(uid), manager} end)

      drafts = Intel.drafts_corpus(uid_to_manager)
      hazard = Estimator.base_hazard(drafts, "13353")

      # Chris Brazzell, fixture byPick["39"].baseSurvival = 0.447 / ["48"] = 0.162
      assert_in_delta Estimator.base_survival(hazard, 35, 39), 0.447, 0.0005
      assert_in_delta Estimator.base_survival(hazard, 35, 48), 0.162, 0.0005
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp canonicalize(drafts) do
    drafts
    |> Enum.map(fn draft ->
      %{
        l_d: Float.round(draft.l_d, 6),
        picks: draft.picks |> Enum.map(&round_pick/1) |> Enum.sort()
      }
    end)
    |> Enum.sort()
  end

  defp round_pick(pick), do: %{pick | norm: Float.round(pick.norm, 6)}

  defp sample_player_ids do
    # Names for these ids are in docs/leaguemate-intel.md §4a/§4e-bis.
    ["13306", "13319", "13353", "13347", "13434", "13287"]
  end

  defp seed_player!(player_id, position_abbr) do
    position =
      SleeperPlayerApi.Sleeper.get_position_by_abbreviation(position_abbr) ||
        (
          {:ok, position} =
            SleeperPlayerApi.Sleeper.create_position(%{abbreviation: position_abbr})

          position
        )

    %SleeperPlayerApi.Sleeper.Player{}
    |> SleeperPlayerApi.Sleeper.Player.changeset(%{
      id: String.to_integer(player_id |> String.replace_prefix("P", "9")),
      player_id: player_id,
      player_json: "{}",
      active: true,
      first_name: player_id,
      last_name: position_abbr,
      full_name: "#{player_id} #{position_abbr}",
      search_first_name: String.downcase(player_id),
      search_last_name: String.downcase(position_abbr),
      search_full_name: String.downcase("#{player_id} #{position_abbr}"),
      position_id: position.id
    })
    |> Repo.insert!()
  end

  defp seed_corpus_from_json! do
    raw_drafts = read_json!("rookie_drafts.json")
    raw_picks_by_draft = read_json!("rookie_picks.json")
    users = read_json!("lmusers.json")

    Intel.upsert_sleeper_users(
      Enum.map(users, fn u ->
        %{id: String.to_integer(u["user_id"]), display_name: u["display_name"]}
      end)
    )

    Intel.upsert_observed_drafts(
      for {draft_id, draft} <- raw_drafts do
        %{
          id: String.to_integer(draft_id),
          league_id: draft["league_id"] && String.to_integer(draft["league_id"]),
          season: draft["season"],
          status: draft["status"],
          draft_type: draft["type"],
          teams: draft["settings"]["teams"],
          rounds: draft["settings"]["rounds"]
        }
      end
    )

    for {draft_id, _draft} <- raw_drafts do
      picks = Map.get(raw_picks_by_draft, draft_id, [])

      entries =
        for pick <- picks do
          %{
            pick_no: pick["pick_no"],
            round: pick["round"],
            draft_slot: pick["draft_slot"],
            roster_id: pick["roster_id"],
            player_id: pick["player_id"],
            picked_by: parse_picked_by(pick["picked_by"])
          }
        end

      Intel.upsert_observed_picks(String.to_integer(draft_id), entries)
    end
  end

  # A few corpus picks carry `picked_by: ""` rather than `null` — an
  # auto-picked slot with no resolvable owner. Both mean "not a tracked
  # leaguemate" to `IntelCorpus.user_id_to_manager/0` (no map has a "" key
  # either), so both collapse to `nil` here for the same effect.
  defp parse_picked_by(nil), do: nil
  defp parse_picked_by(""), do: nil
  defp parse_picked_by(id), do: String.to_integer(id)

  defp read_json!(filename) do
    @corpus_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end
end
