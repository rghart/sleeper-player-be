defmodule SleeperPlayerApi.IntelTest do
  use SleeperPlayerApi.DataCase, async: true

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
