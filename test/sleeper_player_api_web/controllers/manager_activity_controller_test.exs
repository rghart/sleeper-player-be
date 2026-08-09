defmodule SleeperPlayerApiWeb.ManagerActivityControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.Intel

  @league 900
  @alice 111
  @bob 222

  setup %{conn: conn} do
    Intel.upsert_observed_leagues([
      %{
        id: @league,
        name: "A League",
        season: "2026",
        roster_to_user: %{"1" => @alice, "2" => @bob},
        rosters_fetched_at: ~U[2026-08-08 06:00:00Z]
      }
    ])

    Intel.upsert_league_members([
      %{league_id: @league, user_id: @alice},
      %{league_id: @league, user_id: @bob}
    ])

    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp seed(transactions), do: Intel.upsert_observed_transactions(transactions)

  defp tx(id, attrs) do
    Map.merge(
      %{
        id: id,
        league_id: @league,
        week: 1,
        type: "free_agent",
        status: "complete",
        created: ~U[2026-08-01 12:00:00Z],
        creator: @alice,
        participant_ids: [@alice],
        adds: %{},
        drops: %{},
        draft_picks: [],
        waiver_bid: nil
      },
      attrs
    )
  end

  test "returns a manager's activity newest first, with coverage alongside", %{conn: conn} do
    seed([
      tx(1, %{type: "trade", participant_ids: [@alice, @bob], created: ~U[2026-08-01 12:00:00Z]}),
      tx(2, %{type: "waiver", created: ~U[2026-08-05 12:00:00Z], waiver_bid: 12})
    ])

    body = conn |> get(~p"/api/v1/users/#{@alice}/activity?season=2026") |> json_response(200)

    assert Enum.map(body["transactions"], & &1["id"]) == [2, 1]
    assert [%{"type" => "waiver", "waiverBid" => 12} | _] = body["transactions"]

    # Coverage travels with the transactions, always — "2 transactions" means
    # something different across 42 leagues than across 1.
    assert body["coverage"]["leaguesSeen"] == 1
    assert body["coverage"]["leaguesKnown"] == 1
    assert body["coverage"]["lastCrawledAt"] != nil
  end

  test "finds a trade the manager accepted rather than created", %{conn: conn} do
    # bob created nothing; filtering on `creator` would return an empty list
    # and it would look like he simply has no activity.
    seed([tx(1, %{type: "trade", creator: @alice, participant_ids: [@alice, @bob]})])

    body = conn |> get(~p"/api/v1/users/#{@bob}/activity") |> json_response(200)

    assert [%{"id" => 1, "creator" => @alice}] = body["transactions"]
  end

  test "serves failed transactions rather than hiding them", %{conn: conn} do
    seed([tx(1, %{type: "waiver", status: "failed"})])

    body = conn |> get(~p"/api/v1/users/#{@alice}/activity") |> json_response(200)

    assert [%{"status" => "failed"}] = body["transactions"]
  end

  test "resolves the player names behind adds and drops", %{conn: conn} do
    position =
      SleeperPlayerApi.Sleeper.get_position_by_abbreviation("WR") ||
        elem(SleeperPlayerApi.Sleeper.create_position(%{abbreviation: "WR"}), 1)

    %SleeperPlayerApi.Sleeper.Player{}
    |> SleeperPlayerApi.Sleeper.Player.changeset(%{
      id: 4001,
      player_id: "4001",
      player_json: "{}",
      active: true,
      first_name: "Some",
      last_name: "Player",
      full_name: "Some Player",
      search_first_name: "some",
      search_last_name: "player",
      search_full_name: "some player",
      position_id: position.id
    })
    |> SleeperPlayerApi.Repo.insert!()

    seed([tx(1, %{adds: %{"4001" => 1}, drops: %{}})])

    body = conn |> get(~p"/api/v1/users/#{@alice}/activity") |> json_response(200)

    # Ids stay as Sleeper sends them; names ride alongside rather than being
    # repeated into every transaction that touches the same player.
    assert [%{"adds" => %{"4001" => 1}}] = body["transactions"]
    assert body["players"]["4001"]["name"] == "Some Player"
    assert body["players"]["4001"]["position"] == "WR"
  end

  test "says which roster is theirs, so a trade does not render both sides", %{conn: conn} do
    # `adds`/`drops` are league-wide: a trade adds a player to one roster and
    # drops him from another. Seen against live data as
    # "+Marvin Harrison -Marvin Harrison", which reads as nonsense. alice is
    # roster 1, bob roster 2.
    seed([
      tx(1, %{
        type: "trade",
        participant_ids: [@alice, @bob],
        adds: %{"4001" => 1, "4002" => 2},
        drops: %{"4001" => 2, "4002" => 1}
      })
    ])

    alice = conn |> get(~p"/api/v1/users/#{@alice}/activity") |> json_response(200)
    bob = conn |> get(~p"/api/v1/users/#{@bob}/activity") |> json_response(200)

    assert [%{"rosterId" => 1}] = alice["transactions"]
    assert [%{"rosterId" => 2}] = bob["transactions"]
  end

  test "leaves rosterId null when the league's roster map is unknown", %{conn: conn} do
    # A league whose /rosters call failed still serves its transactions; the
    # caller shows the move unsided rather than showing nothing.
    Intel.upsert_observed_leagues([%{id: 901, name: "No map", season: "2026"}])
    Intel.upsert_league_members([%{league_id: 901, user_id: @alice}])
    seed([tx(9, %{league_id: 901})])

    body = conn |> get(~p"/api/v1/users/#{@alice}/activity") |> json_response(200)

    assert [%{"rosterId" => nil}] = body["transactions"]
  end

  test "narrows by type and caps at a limit", %{conn: conn} do
    seed([
      tx(1, %{type: "trade", created: ~U[2026-08-01 12:00:00Z]}),
      tx(2, %{type: "waiver", created: ~U[2026-08-02 12:00:00Z]}),
      tx(3, %{type: "waiver", created: ~U[2026-08-03 12:00:00Z]})
    ])

    typed = conn |> get(~p"/api/v1/users/#{@alice}/activity?types=trade") |> json_response(200)
    assert Enum.map(typed["transactions"], & &1["id"]) == [1]

    capped = conn |> get(~p"/api/v1/users/#{@alice}/activity?limit=1") |> json_response(200)
    assert length(capped["transactions"]) == 1
  end

  test "an unknown manager is an empty list with honest coverage, not an error", %{conn: conn} do
    # Nothing stored for them is a real state — a quiet manager, or a crawl
    # that has not reached their leagues — not a 404.
    body = conn |> get(~p"/api/v1/users/999999/activity?season=2026") |> json_response(200)

    assert body["transactions"] == []
    assert body["coverage"]["leaguesSeen"] == 0
    # Not a member of anything we know about, so the denominator is theirs: 0.
    assert body["coverage"]["leaguesKnown"] == 0
  end

  test "a non-numeric limit is a 422, not a 500", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/users/#{@alice}/activity?limit=abc")

    assert json_response(conn, 422)["errors"]["detail"] =~ "limit must be an integer"
  end
end
