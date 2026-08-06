defmodule SleeperPlayerApiWeb.AvailabilityControllerTest do
  # Bypass owns a real port and this module points the client at it via the
  # shared `:sleeper_base_url` Application env key (same trick as
  # `test/sleeper_player_api/tasks/crawl_leaguemate_drafts_test.exs`), so
  # this suite can't run concurrently with itself or anything else that
  # touches that key.
  use SleeperPlayerApiWeb.ConnCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.ObservedDraft
  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts

  @corpus_dir Path.expand("../../support/corpus", __DIR__)
  @draft_id "1313425233306198016"
  @league_id "1313425233297813504"
  @ryangh_user_id "521035584588267520"

  setup %{conn: conn} do
    bypass = Bypass.open()
    Application.put_env(:sleeper_player_api, :sleeper_base_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :sleeper_base_url)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), bypass: bypass}
  end

  describe "GET /api/v1/drafts/:draft_id/availability — District 13, §4f acceptance case" do
    @describetag :corpus

    setup %{bypass: bypass} do
      seed_corpus_from_json!()
      seed_target_players!()
      stub_district_13(bypass)
      :ok
    end

    test "resolves the trade-resolved board: atekipp owns both pick 35 and pick 37", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/api/v1/drafts/#{@draft_id}/availability?user_id=#{@ryangh_user_id}&limit=60"
        )

      body = json_response(conn, 200)

      assert body["league"] == "District 13 Dynasty League"
      assert body["draftId"] == String.to_integer(@draft_id)
      assert body["currentPick"] == 35
      assert body["lastPick"] == 48
      assert body["teams"] == 12
      assert body["rounds"] == 4
      assert body["myPicks"] == [39]
      assert body["corpusDrafts"] == 70
      assert body["tradedPicksApplied"] == true

      board = Enum.map(body["board"], &{&1["pick"], &1["manager"]})

      # The naive `draft_order`/`slot_to_roster_id` version could never
      # produce this (§4f) — atekipp holds two of the four picks before
      # pick 39 only because of the traded 3rd-round pick.
      assert board == [
               {35, "atekipp"},
               {36, "cja9689"},
               {37, "atekipp"},
               {38, "cunglomerate"},
               {39, "ryangh"},
               {40, "baconstains"},
               {41, "pavelito0010"},
               {42, "GetForked"},
               {43, "pavelito0010"},
               {44, "N8TEDAGR38T"},
               {45, "atekipp"},
               {46, "babaghanoush123"},
               {47, "skeefe"},
               {48, "cja9689"}
             ]

      pick39 = Enum.find(body["board"], &(&1["pick"] == 39))
      assert pick39["mine"] == true
    end

    test "byPick numbers match the fixture within 0.0005 — proves the whole stack", %{conn: conn} do
      fixture = read_json!("fixture.json")

      conn =
        get(
          conn,
          ~p"/api/v1/drafts/#{@draft_id}/availability?user_id=#{@ryangh_user_id}&limit=60"
        )

      body = json_response(conn, 200)

      targets_by_id = Map.new(body["targets"], &{&1["id"], &1})

      deviations =
        Enum.flat_map(fixture["targets"], fn expected_target ->
          actual_target = Map.fetch!(targets_by_id, expected_target["id"])

          Enum.map(expected_target["byPick"], fn {pick_str, expected} ->
            actual = Map.fetch!(actual_target["byPick"], pick_str)

            assert_in_delta actual["baseSurvival"],
                            expected["baseSurvival"],
                            0.0005,
                            "baseSurvival mismatch for #{expected_target["name"]} @ #{pick_str}"

            assert_in_delta actual["adjSurvival"],
                            expected["adjSurvival"],
                            0.0005,
                            "adjSurvival mismatch for #{expected_target["name"]} @ #{pick_str}"

            assert length(actual["threats"]) == length(expected["threats"]),
                   "threat count mismatch for #{expected_target["name"]} @ #{pick_str}"

            Enum.zip(actual["threats"], expected["threats"])
            |> Enum.each(fn {a, e} ->
              assert a["manager"] == e["manager"]
              assert a["pick"] == e["pick"]

              assert_in_delta a["prob"],
                              e["prob"],
                              0.0005,
                              "threat prob mismatch for #{expected_target["name"]} @ #{pick_str}, owner #{a["manager"]}"
            end)

            [
              abs(actual["baseSurvival"] - expected["baseSurvival"]),
              abs(actual["adjSurvival"] - expected["adjSurvival"])
            ]
          end)
        end)
        |> List.flatten()

      max_deviation = Enum.max(deviations)

      IO.puts("""

      Endpoint-vs-fixture deviations (tolerance 0.0005):
        max #{Float.round(max_deviation, 6)} over #{length(deviations)} baseSurvival/adjSurvival values
      """)

      assert max_deviation <= 0.0005
    end
  end

  describe "GET /api/v1/drafts/:draft_id/availability — no crawled corpus at all" do
    # Reads `lmusers.json` (below) to seed leaguemate names, so it needs the
    # same `:corpus` gate as the acceptance-case block above.
    @describetag :corpus

    setup %{bypass: bypass} do
      # Leaguemates are still known (`sleeper_users`, from a prior
      # `/league/:id/users` crawl) so board manager names resolve — it's
      # specifically the *corpus* of completed rookie drafts that's
      # missing, which is the failure behaviour §3e is about.
      seed_users_only!()
      stub_district_13(bypass)
      :ok
    end

    test "still resolves the board (trade resolution doesn't need the corpus), but targets is empty — never a fabricated survival read",
         %{conn: conn} do
      conn = get(conn, ~p"/api/v1/drafts/#{@draft_id}/availability?user_id=#{@ryangh_user_id}")
      body = json_response(conn, 200)

      assert body["corpusDrafts"] == 0
      assert body["targets"] == []
      assert Enum.find(body["board"], &(&1["pick"] == 35))["manager"] == "atekipp"
    end
  end

  describe "GET /api/v1/drafts/:draft_id/availability — draft state produced by the crawler, not seeded" do
    # Regression for a production 500. Every other describe block above
    # seeds `observed_drafts` directly (`seed_corpus_from_json!`,
    # `upsert_observed_drafts` in this file's own helpers), which writes
    # whatever `slot_to_roster_id` the test fixture happens to include.
    # That's not what the crawler can ever actually produce: `GET
    # /user/:id/drafts/nfl/:season` — the only call `CrawlLeaguemateDrafts`
    # makes to discover a draft — doesn't return `slot_to_roster_id` at
    # all. So a draft that's `"complete"` (never refreshed again by
    # `ensure_fresh/1`) has `slot_to_roster_id: nil` in the DB forever once
    # it's gone through a *real* `CrawlLeaguemateDrafts.crawl/2`, not a
    # seeding helper — and `/availability` 500'd on exactly that column
    # against real production data.
    #
    # This block runs the actual crawler against Bypass stubs shaped like
    # real Sleeper responses (no `slot_to_roster_id` on the listing call,
    # same as `CrawlLeaguemateDraftsTest`'s fixtures), then hits
    # `/availability` against the state it left behind.
    @small_league_id "999"
    @small_user_id "100"
    @small_draft_id "5000"

    defp small_draft(status) do
      %{
        "draft_id" => @small_draft_id,
        "league_id" => @small_league_id,
        "season" => "2026",
        "status" => status,
        "type" => "linear",
        "start_time" => 1_700_000_000_000,
        "settings" => %{"player_type" => 1, "teams" => 2, "rounds" => 3}
        # Deliberately no "slot_to_roster_id" key — real
        # `/user/:id/drafts/nfl/:season` responses don't have one either.
      }
    end

    defp small_pick(pick_no, player_id, picked_by) do
      %{
        "pick_no" => pick_no,
        "round" => 1,
        "draft_slot" => pick_no,
        "roster_id" => pick_no,
        "player_id" => player_id,
        "picked_by" => picked_by
      }
    end

    setup %{bypass: bypass} do
      respond_json(bypass, "GET", "/league/#{@small_league_id}/users", [
        %{"user_id" => @small_user_id, "username" => "alice_u", "display_name" => "alice"}
      ])

      respond_json(bypass, "GET", "/user/#{@small_user_id}/drafts/nfl/2026", [
        small_draft("complete")
      ])

      # Only 2 of the draft's 6 picks are "made" — leaves picks 3-6 for
      # `/availability` to resolve against `slot_to_roster_id`, which is
      # exactly the path that raised.
      respond_json(bypass, "GET", "/draft/#{@small_draft_id}/picks", [
        small_pick(1, "P1", @small_user_id),
        small_pick(2, "P2", nil)
      ])

      # `/availability`'s live fetch for the analyzed draft — the fix under
      # test. Has to be the full draft object (status "complete" here,
      # matching what's stored) with a real `slot_to_roster_id`, unlike the
      # listing call above.
      respond_json(bypass, "GET", "/draft/#{@small_draft_id}", %{
        "draft_id" => @small_draft_id,
        "league_id" => @small_league_id,
        "status" => "complete",
        "type" => "linear",
        "slot_to_roster_id" => %{"1" => 1, "2" => 2}
      })

      respond_json(bypass, "GET", "/league/#{@small_league_id}/rosters", [
        %{"roster_id" => 1, "owner_id" => @small_user_id},
        %{"roster_id" => 2, "owner_id" => "200"}
      ])

      assert {:ok, %{drafts_fetched: 1}} = CrawlLeaguemateDrafts.crawl(@small_league_id, "2026")

      assert %ObservedDraft{status: "complete", slot_to_roster_id: nil} =
               Repo.get!(ObservedDraft, String.to_integer(@small_draft_id))

      :ok
    end

    test "resolves the board instead of 500ing on the crawler's own slot_to_roster_id gap", %{
      conn: conn
    } do
      conn =
        get(conn, ~p"/api/v1/drafts/#{@small_draft_id}/availability?user_id=#{@small_user_id}")

      body = json_response(conn, 200)

      assert body["currentPick"] == 3
      assert body["lastPick"] == 6

      board = Enum.map(body["board"], &{&1["pick"], &1["mine"]})
      # slot 1 -> roster 1 -> alice (owner_id 100, this request's user);
      # slot 2 -> roster 2 -> owner_id 200, not this request's user.
      assert board == [{3, true}, {4, false}, {5, true}, {6, false}]
    end
  end

  describe "GET /api/v1/drafts/:draft_id/availability — validation" do
    test "missing user_id is a 422, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/drafts/#{@draft_id}/availability")
      assert json_response(conn, 422)
    end
  end

  # ---------------------------------------------------------------------
  # Bypass stubs — the live draft-refresh + roster-ownership fetch path
  # ---------------------------------------------------------------------

  defp stub_district_13(bypass) do
    respond_json(bypass, "GET", "/draft/#{@draft_id}", read_json!("d13.json"))
    respond_json(bypass, "GET", "/draft/#{@draft_id}/picks", read_json!("d13_now.json"))
    respond_json(bypass, "GET", "/draft/#{@draft_id}/traded_picks", read_json!("d13_traded.json"))
    respond_json(bypass, "GET", "/league/#{@league_id}/rosters", read_json!("d13_rosters.json"))
  end

  defp respond_json(bypass, method, path, body) do
    Bypass.stub(bypass, method, path, fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(body))
    end)
  end

  # ---------------------------------------------------------------------
  # Corpus seeding — same shaping as
  # `test/sleeper_player_api/intel_test.exs`'s `seed_corpus_from_json!/0`
  # ---------------------------------------------------------------------

  # `eligible_ids` (`Intel.fantasy_position_ids/1`) restricts `targets` to
  # players with a QB/RB/WR/TE row in `players` — populated in production
  # by the nightly `GetSleeperPlayerData` job, empty here since this test
  # doesn't run it. Seed just the fixture's 16 target players directly
  # (names/positions from the corpus's own pick metadata) rather than the
  # whole ~9,400-player dump.
  @target_players [
    {"13353", "Chris", "Brazzell", "WR"},
    {"13289", "Drew", "Allar", "QB"},
    {"13347", "Demond", "Claiborne", "RB"},
    {"13319", "Oscar", "Delp", "TE"},
    {"13302", "Adam", "Randall", "RB"},
    {"13303", "Cade", "Klubnik", "QB"},
    {"13400", "Justin", "Joly", "TE"},
    {"13434", "Will", "Kacmarek", "TE"},
    {"13404", "Garrett", "Nussmeier", "QB"},
    {"13306", "Taylen", "Green", "QB"},
    {"13423", "Eli", "Heidenreich", "RB"},
    {"13420", "Bryce", "Lance", "WR"},
    {"13348", "J'Mari", "Taylor", "RB"},
    {"13401", "Michael", "Trigg", "TE"},
    {"13333", "Deion", "Burks", "WR"},
    {"13424", "Seth", "McGowan", "RB"}
  ]

  defp seed_target_players! do
    Enum.each(@target_players, fn {player_id, first_name, last_name, position_abbr} ->
      position =
        SleeperPlayerApi.Sleeper.get_position_by_abbreviation(position_abbr) ||
          (
            {:ok, position} =
              SleeperPlayerApi.Sleeper.create_position(%{abbreviation: position_abbr})

            position
          )

      full_name = "#{first_name} #{last_name}"

      %SleeperPlayerApi.Sleeper.Player{}
      |> SleeperPlayerApi.Sleeper.Player.changeset(%{
        id: String.to_integer(player_id),
        player_id: player_id,
        player_json: "{}",
        active: true,
        first_name: first_name,
        last_name: last_name,
        full_name: full_name,
        search_first_name: String.downcase(first_name),
        search_last_name: String.downcase(last_name),
        search_full_name: String.downcase(full_name),
        position_id: position.id
      })
      |> SleeperPlayerApi.Repo.insert!()
    end)
  end

  defp seed_users_only! do
    users = read_json!("lmusers.json")

    Intel.upsert_sleeper_users(
      Enum.map(users, fn u ->
        %{id: String.to_integer(u["user_id"]), display_name: u["display_name"]}
      end)
    )
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
