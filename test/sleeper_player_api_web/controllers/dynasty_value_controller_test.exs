defmodule SleeperPlayerApiWeb.DynastyValueControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Intel.PlayerValueHistory

  defp seed_value(player_id, source, value, rank) do
    Intel.upsert_player_values([
      %{
        player_id: player_id,
        source: source,
        value: value,
        overall_rank: rank,
        position_rank: 1,
        roster_percent: nil,
        trade_frequency: nil,
        draft_year: nil,
        as_of: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])
  end

  defp seed_history(player_id, source, value, days_ago) do
    day = Date.add(Date.utc_today(), -days_ago)

    Repo.insert!(%PlayerValueHistory{
      player_id: player_id,
      source: source,
      day: day,
      value: value,
      as_of: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
      updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
  end

  test "serves superflex by default, with movement over 30 days", %{conn: conn} do
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 5000.0, 30)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert body["source"] == "keeptradecut:sf"
    assert body["window"] == 30

    assert [%{"playerId" => "4984", "value" => 6000.0, "change" => 1000.0, "changePct" => 20.0}] =
             body["values"]
  end

  test "superflex=false switches variant, and the two do not bleed", %{conn: conn} do
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_value(4984, "keeptradecut:1qb", 4000.0, 9)

    body = conn |> get(~p"/api/v1/dynasty-values?superflex=false") |> json_response(200)

    assert body["source"] == "keeptradecut:1qb"
    assert [%{"value" => 4000.0, "overallRank" => 9}] = body["values"]
  end

  test "compares against the most recent close on or before the target day", %{conn: conn} do
    # No row exactly 30 days back — a gap, or a series that starts late. The
    # comparison must fall back to the nearest earlier close rather than
    # reporting no movement, and must say which day it used.
    #
    # **Two candidates inside the lookback, deliberately.** With only one the
    # seek's ORDER BY is unpinned: newest-first and oldest-first return the
    # same row and reversing it leaves every test green. A sabotage run caught
    # exactly that.
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 5500.0, 40)
    seed_history(4984, "keeptradecut:sf", 5800.0, 32)
    # Inside the window, so it must NOT be chosen as the baseline.
    seed_history(4984, "keeptradecut:sf", 5900.0, 3)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    # 32 days back, not 40: the most recent close on or before the target.
    assert [%{"change" => 200.0, "since" => since}] = body["values"]
    assert since == Date.to_iso8601(Date.add(Date.utc_today(), -32))
  end

  test "ignores a close older than the lookback bound rather than calling it 30 days", %{
    conn: conn
  } do
    # 100 days back is not a 30-day comparison, and labelling it one would be
    # a false statement. It is also what made the query scan the whole series
    # and take 14s cold in production.
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 1000.0, 100)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert [%{"change" => nil, "since" => nil}] = body["values"]
  end

  test "still finds a close just inside the lookback bound", %{conn: conn} do
    # 30 + 13 days: inside the two-week reach, so a real gap in the series is
    # still bridged rather than silenced.
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 5000.0, 43)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert [%{"change" => 1000.0}] = body["values"]
  end

  test "change is null, not zero, when there is nothing to compare against", %{conn: conn} do
    # Flat and unknown are different answers; collapsing them would have the
    # UI render "0" for a player it has never seen before.
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert [%{"change" => nil, "changePct" => nil, "since" => nil}] = body["values"]
  end

  test "a genuinely flat player reports zero, not null", %{conn: conn} do
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 6000.0, 30)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert [%{"change" => +0.0, "changePct" => +0.0}] = body["values"]
  end

  test "window is configurable", %{conn: conn} do
    seed_value(4984, "keeptradecut:sf", 6000.0, 1)
    seed_history(4984, "keeptradecut:sf", 3000.0, 7)
    seed_history(4984, "keeptradecut:sf", 5000.0, 30)

    body = conn |> get(~p"/api/v1/dynasty-values?window=7") |> json_response(200)

    assert body["window"] == 7
    assert [%{"change" => 3000.0}] = body["values"]
  end

  test "picks come back alongside the players", %{conn: conn} do
    Intel.upsert_draft_pick_values([
      %{
        season: 2027,
        round: 1,
        tier: "mid",
        source: "keeptradecut:sf",
        value: 5512.0,
        overall_rank: 20,
        position_rank: nil,
        as_of: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert [%{"season" => 2027, "round" => 1, "tier" => "mid", "value" => 5512.0}] = body["picks"]
  end

  test "values come back best first", %{conn: conn} do
    seed_value(1, "keeptradecut:sf", 100.0, 3)
    seed_value(2, "keeptradecut:sf", 900.0, 1)
    seed_value(3, "keeptradecut:sf", 500.0, 2)

    body = conn |> get(~p"/api/v1/dynasty-values") |> json_response(200)

    assert Enum.map(body["values"], & &1["overallRank"]) == [1, 2, 3]
  end

  test "a non-numeric window is a 422 rather than a silent default", %{conn: conn} do
    body = conn |> get(~p"/api/v1/dynasty-values?window=soon") |> json_response(422)
    assert body["errors"]["detail"] =~ "must be an integer"
  end

  test "an out-of-range window is a 422, and says the range", %{conn: conn} do
    body = conn |> get(~p"/api/v1/dynasty-values?window=0") |> json_response(422)
    assert body["errors"]["detail"] =~ "between 1 and 1000"
  end
end
