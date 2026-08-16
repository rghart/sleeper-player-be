defmodule SleeperPlayerApiWeb.FaabControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.Intel

  defp league(id, attrs \\ %{}) do
    Intel.upsert_observed_leagues([
      Map.merge(%{id: id, season: "2026", waiver_type: 2, waiver_budget: 100}, attrs)
    ])
  end

  defp claim(id, league_id, player_id, bid, attrs \\ %{}) do
    Intel.upsert_observed_transactions([
      Map.merge(
        %{
          id: id,
          league_id: league_id,
          week: 1,
          type: "waiver",
          status: "complete",
          created: ~U[2026-06-15 12:00:00Z],
          creator: 111,
          participant_ids: [111],
          adds: %{player_id => 1},
          drops: %{},
          waiver_bid: bid
        },
        attrs
      )
    ])
  end

  test "serves a price as a share of budget, with its spread and denominator", %{conn: conn} do
    league(900, %{waiver_budget: 100})
    league(901, %{waiver_budget: 1000})
    claim(1, 900, "4034", 50)
    claim(2, 901, "4034", 50)

    body = conn |> get(~p"/api/v1/faab") |> json_response(200)

    assert %{"median" => 27.5, "low" => 5.0, "high" => 50.0, "claims" => 2, "leagues" => 2} =
             body["players"]["4034"]
  end

  # The prices mean nothing without these, so they ride on the envelope rather
  # than being a second request a caller can forget to make.
  test "the window and league count travel with the prices", %{conn: conn} do
    league(900)
    claim(1, 900, "4034", 10, %{created: ~U[2026-05-02 09:00:00Z]})
    claim(2, 900, "6794", 20, %{created: ~U[2026-07-30 09:00:00Z]})

    body = conn |> get(~p"/api/v1/faab") |> json_response(200)

    assert body["window"] == %{"from" => "2026-05-02", "to" => "2026-07-30"}
    assert body["leagues"] == 1
  end

  test "an empty corpus sends a null window rather than an invented one", %{conn: conn} do
    body = conn |> get(~p"/api/v1/faab") |> json_response(200)

    assert body["window"] == nil
    assert body["players"] == %{}
  end

  test "minClaims narrows to the well-sampled players", %{conn: conn} do
    league(900)
    league(901)
    claim(1, 900, "4034", 10)
    claim(2, 901, "4034", 20)
    claim(3, 900, "6794", 30)

    body = conn |> get(~p"/api/v1/faab?minClaims=2") |> json_response(200)

    assert Map.keys(body["players"]) == ["4034"]
  end

  test "a non-numeric minClaims is a 422 rather than a silent default", %{conn: conn} do
    assert conn |> get(~p"/api/v1/faab?minClaims=lots") |> json_response(422)
  end

  test "an out-of-range minClaims is a 422, and says the range", %{conn: conn} do
    body = conn |> get(~p"/api/v1/faab?minClaims=0") |> json_response(422)

    assert body["errors"] |> inspect() =~ "100"
  end

  # Sleeper ids are strings on the wire everywhere in this API — a caller
  # keying one map by number and another by string finds out at runtime.
  test "keys players by string id", %{conn: conn} do
    league(900)
    claim(1, 900, "4034", 10)

    body = conn |> get(~p"/api/v1/faab") |> json_response(200)

    assert ["4034"] = Map.keys(body["players"])
  end
end
