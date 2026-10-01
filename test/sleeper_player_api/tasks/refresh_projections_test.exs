defmodule SleeperPlayerApi.Tasks.RefreshProjectionsTest do
  # Points the projections client at Bypass through shared Application env.
  use SleeperPlayerApi.DataCase, async: false

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Tasks.RefreshProjections

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :sleeper_player_api,
      :sleeper_projections_base_url,
      "http://localhost:#{bypass.port}"
    )

    on_exit(fn -> Application.delete_env(:sleeper_player_api, :sleeper_projections_base_url) end)
    {:ok, bypass: bypass}
  end

  defp row(id, rec),
    do: %{"player_id" => id, "stats" => %{"rec" => rec}, "last_modified" => 1_790_754_624_517}

  defp respond(bypass, status, body) do
    Bypass.expect_once(bypass, "GET", "/projections/nfl/2026", fn conn ->
      # The positions are asked for explicitly; without them Sleeper sends
      # every IDP too.
      assert conn.query_string =~ "season_type=regular"
      assert conn.query_string =~ URI.encode_query(%{"position[]" => "QB"})
      Plug.Conn.resp(conn, status, body)
    end)
  end

  test "stores a season, and a later fetch replaces it exactly", %{bypass: bypass} do
    respond(bypass, 200, Jason.encode!([row("1", 50), row("2", 40)]))
    assert {:ok, 2} = RefreshProjections.refresh(2026)

    # Player 2 dropped out of Sleeper's list and player 1 was re-projected:
    # the table holds exactly the latest fetch.
    respond(bypass, 200, Jason.encode!([row("1", 60), row("3", 30)]))
    assert {:ok, 2} = RefreshProjections.refresh(2026)

    assert Intel.projections(2026) == [
             %{"player_id" => "1", "stats" => %{"rec" => 60}},
             %{"player_id" => "3", "stats" => %{"rec" => 30}}
           ]
  end

  test "an empty fetch keeps what was stored rather than pruning everyone", %{bypass: bypass} do
    respond(bypass, 200, Jason.encode!([row("1", 50)]))
    RefreshProjections.refresh(2026)

    respond(bypass, 200, "[]")
    assert {:error, :empty} = RefreshProjections.refresh(2026)
    assert length(Intel.projections(2026)) == 1
  end

  test "a failed fetch changes nothing", %{bypass: bypass} do
    respond(bypass, 200, Jason.encode!([row("1", 50)]))
    RefreshProjections.refresh(2026)

    respond(bypass, 503, "down")
    assert {:error, {:http_error, 503}} = RefreshProjections.refresh(2026)
    assert length(Intel.projections(2026)) == 1
  end

  test "ensure/1 fetches only when nothing is stored", %{bypass: bypass} do
    # `respond/3` is expect_once: a second fetch would fail the test.
    respond(bypass, 200, Jason.encode!([row("1", 50)]))

    assert RefreshProjections.ensure(2026)
    assert RefreshProjections.ensure(2026)
    assert [%{"player_id" => "1"}] = Intel.projections(2026)
    assert [%{"player_id" => "1"}] = Intel.projections(2026, ["1", "2"])
    assert [] = Intel.projections(2026, ["2"])
    assert %DateTime{} = Intel.projections_as_of(2026)
  end

  test "ensure/1 is false when Sleeper has nothing for the season", %{bypass: bypass} do
    respond(bypass, 200, "[]")

    refute RefreshProjections.ensure(2026)
  end
end
