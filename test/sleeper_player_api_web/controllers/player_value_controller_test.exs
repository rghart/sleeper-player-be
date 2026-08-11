defmodule SleeperPlayerApiWeb.PlayerValueControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.Intel

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp seed(values), do: Intel.upsert_player_values(values)

  defp value(player_id, attrs) do
    Map.merge(
      %{
        player_id: player_id,
        source: "fantasycalc",
        value: 1000.0,
        overall_rank: 1,
        position_rank: 1,
        roster_percent: 90.0,
        trade_frequency: 1.0,
        as_of: ~U[2026-08-10 08:30:00Z],
        draft_year: 2025
        # No inserted_at/updated_at: `insert_all_batched` stamps them, and
        # they are naive datetimes while `as_of` is a real one.
      },
      attrs
    )
  end

  describe "GET /api/v1/values" do
    test "returns the values best player first", %{conn: conn} do
      seed([
        value(3, %{overall_rank: 3, value: 800.0}),
        value(1, %{overall_rank: 1, value: 1000.0}),
        value(2, %{overall_rank: 2, value: 900.0})
      ])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1", "2", "3"]
    end

    # Sleeper ids are strings on the wire everywhere else in this API, and a
    # caller keying one map by a number and another by a string finds out at
    # runtime rather than at the boundary.
    test "sends player ids as strings", %{conn: conn} do
      seed([value(12_345, %{})])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert [%{"playerId" => "12345"}] = body["values"]
    end

    test "carries the rank and value behind each player", %{conn: conn} do
      seed([value(7, %{overall_rank: 4, position_rank: 2, value: 850.5})])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert [%{"overallRank" => 4, "positionRank" => 2, "value" => 850.5}] = body["values"]
    end

    # Postgres sorts nulls first on ASC, so without NULLS LAST a player the
    # feed has no opinion on would open the ranking list.
    test "puts a player with no overall rank last, not first", %{conn: conn} do
      seed([
        value(9, %{overall_rank: nil}),
        value(1, %{overall_rank: 1}),
        value(2, %{overall_rank: 2})
      ])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1", "2", "9"]
    end

    test "reports the settings the values are of", %{conn: conn} do
      seed([value(1, %{})])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert body["settings"] == %{
               "source" => "fantasycalc",
               "format" => "dynasty",
               "numQbs" => 2,
               "numTeams" => 12,
               "ppr" => 1
             }
    end

    test "reports the freshest timestamp in the list", %{conn: conn} do
      seed([
        value(1, %{overall_rank: 1, as_of: ~U[2026-08-09 08:30:00Z]}),
        value(2, %{overall_rank: 2, as_of: ~U[2026-08-10 08:30:00Z]})
      ])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert body["asOf"] == "2026-08-10T08:30:00Z"
    end

    # Before the nightly refresh has ever run. An empty list and a null
    # timestamp is the honest answer; a fabricated `now` would tell the caller
    # its empty list was current.
    test "answers with nothing rather than inventing a timestamp", %{conn: conn} do
      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert body["values"] == []
      assert body["asOf"] == nil
    end

    # `player_values` is keyed by (player_id, source) and the schema is built
    # for more than one provider. Another source's rows must not leak into a
    # list presented as FantasyCalc's.
    test "returns only the FantasyCalc rows", %{conn: conn} do
      seed([
        value(1, %{overall_rank: 1}),
        value(2, %{source: "somewhere_else", overall_rank: 2})
      ])

      body = conn |> get(~p"/api/v1/values") |> json_response(200)

      assert Enum.map(body["values"], & &1["playerId"]) == ["1"]
    end
  end
end
