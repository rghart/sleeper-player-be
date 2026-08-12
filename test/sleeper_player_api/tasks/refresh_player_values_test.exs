defmodule SleeperPlayerApi.Tasks.RefreshPlayerValuesTest do
  # Bypass owns a real port and this module points the FantasyCalc client at
  # it via :fantasy_calc_base_url, same trick as every other Bypass-backed
  # suite in this repo — can't run concurrently with itself.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Tasks.RefreshPlayerValues
  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Intel.PlayerValueHistory

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :fantasy_calc_base_url,
      "http://localhost:#{bypass.port}"
    )

    on_exit(fn ->
      Application.delete_env(:sleeper_player_api, :fantasy_calc_base_url)
    end)

    {:ok, bypass: bypass}
  end

  defp entry(sleeper_id, value, draft_info \\ nil) do
    player =
      %{"name" => "Player #{sleeper_id}", "sleeperId" => sleeper_id, "position" => "WR"}
      |> then(fn p -> if draft_info, do: Map.put(p, "maybeDraftInfo", draft_info), else: p end)

    %{
      "player" => player,
      "value" => value,
      "overallRank" => 1,
      "positionRank" => 1,
      "maybeRosterPercent" => 0.5,
      "maybeTradeFrequency" => 0.02
    }
  end

  test "fetches from FantasyCalc via Bypass and upserts into player_values (default source, not seeded)",
       %{bypass: bypass} do
    payload = [
      entry("13353", 4200, %{"year" => 2026, "round" => 3, "pick" => 7}),
      entry("4984", 10_000)
    ]

    Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(payload))
    end)

    assert {:ok, 2} = RefreshPlayerValues.refresh_player_values()

    rows = Repo.all(PlayerValue) |> Enum.sort_by(& &1.player_id)
    assert [%{player_id: 4984, draft_year: nil}, %{player_id: 13353, draft_year: 2026}] = rows
    assert Enum.find(rows, &(&1.player_id == 13353)).value == 4200.0
    assert Enum.find(rows, &(&1.player_id == 13353)).source == "fantasycalc"
  end

  test "a second run overwrites the same (player_id, source) row instead of duplicating", %{
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/values/current", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!([entry("13353", 4200)]))
    end)

    assert {:ok, 1} = RefreshPlayerValues.refresh_player_values()
    assert {:ok, 1} = RefreshPlayerValues.refresh_player_values()

    assert [%{value: 4200.0}] = Repo.all(PlayerValue)
  end

  test "a fetch failure returns {:error, reason} and upserts nothing", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
      Plug.Conn.resp(conn, 503, "boom")
    end)

    assert {:error, {:http_error, 503}} = RefreshPlayerValues.refresh_player_values()
    assert Repo.all(PlayerValue) == []
    assert Repo.all(PlayerValueHistory) == []
  end

  test "every refresh also records the day's close into player_value_history", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/values/current", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!([entry("13353", 4200), entry("4984", 10_000)]))
    end)

    assert {:ok, 2} = RefreshPlayerValues.refresh_player_values()

    rows = Repo.all(PlayerValueHistory) |> Enum.sort_by(& &1.player_id)
    assert [%{player_id: 4984}, %{player_id: 13353, value: 4200.0, source: "fantasycalc"}] = rows
    assert Enum.all?(rows, &(&1.day == Date.utc_today()))
  end

  test "two runs on the same day collapse to one row per player, holding the later value" do
    # Not driven through Bypass: the point is the (player_id, source, day)
    # conflict, and going through the client would make this a test about two
    # HTTP responses instead. `as_of` is what decides the day, so it is set
    # explicitly rather than left to the clock.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    shaped = fn value ->
      [
        %{
          player_id: 13_353,
          source: "fantasycalc",
          value: value,
          overall_rank: 1,
          position_rank: 1,
          roster_percent: nil,
          trade_frequency: nil,
          draft_year: nil,
          as_of: now
        }
      ]
    end

    assert {1, _} = SleeperPlayerApi.Intel.record_value_history(shaped.(4200.0))
    assert {1, _} = SleeperPlayerApi.Intel.record_value_history(shaped.(4500.0))

    assert [%{value: 4500.0, day: day}] = Repo.all(PlayerValueHistory)
    assert day == DateTime.to_date(now)
  end

  test "the same player on two different days keeps both rows" do
    # The whole reason the table exists — a second day must not overwrite the
    # first, or there is no series to read a trend off.
    today = DateTime.utc_now() |> DateTime.truncate(:second)
    yesterday = DateTime.add(today, -1, :day)

    row = fn value, as_of ->
      [
        %{
          player_id: 13_353,
          source: "fantasycalc",
          value: value,
          overall_rank: 1,
          position_rank: 1,
          as_of: as_of
        }
      ]
    end

    assert {1, _} = SleeperPlayerApi.Intel.record_value_history(row.(4000.0, yesterday))
    assert {1, _} = SleeperPlayerApi.Intel.record_value_history(row.(4400.0, today))

    assert [4000.0, 4400.0] =
             Repo.all(PlayerValueHistory) |> Enum.sort_by(& &1.day) |> Enum.map(& &1.value)
  end

  test "an entry with no as_of is dropped rather than dated by guesswork" do
    # A history row whose date was guessed would silently overwrite a real
    # close for that day, which is worse than having no row at all.
    entries = [
      %{player_id: 13_353, source: "fantasycalc", value: 4200.0},
      %{
        player_id: 4984,
        source: "fantasycalc",
        value: 9000.0,
        as_of: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ]

    assert {1, _} = SleeperPlayerApi.Intel.record_value_history(entries)
    assert [%{player_id: 4984}] = Repo.all(PlayerValueHistory)
  end
end
