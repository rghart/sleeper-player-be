defmodule SleeperPlayerApi.Tasks.RefreshPlayerValuesTest do
  # Bypass owns a real port and this module points the FantasyCalc client at
  # it via :fantasy_calc_base_url, same trick as every other Bypass-backed
  # suite in this repo — can't run concurrently with itself.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Tasks.RefreshPlayerValues
  alias SleeperPlayerApi.Intel.PlayerValue

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
  end
end
