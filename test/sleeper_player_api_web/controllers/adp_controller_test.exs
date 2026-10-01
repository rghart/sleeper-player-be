defmodule SleeperPlayerApiWeb.AdpControllerTest do
  use SleeperPlayerApiWeb.ConnCase, async: true

  alias SleeperPlayerApi.{Intel, Market}

  @recent DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.truncate(:second)
  @old DateTime.utc_now() |> DateTime.add(-400 * 86_400, :second) |> DateTime.truncate(:second)

  # Seeds a complete superflex startup draft whose picks are `order`, first
  # pick first.
  defp startup(id, order, opts \\ []) do
    teams = 8
    rounds = div(length(order), teams)

    {:ok, _} =
      Market.store_draft(
        %{
          id: id,
          kind: Keyword.get(opts, :kind, "startup"),
          teams: teams,
          rounds: rounds,
          qb_slots: Keyword.get(opts, :qb_slots, 2),
          te_premium: Keyword.get(opts, :te_premium, 0.0),
          started_at: Keyword.get(opts, :started_at, @recent)
        },
        order
        |> Enum.with_index(1)
        |> Enum.map(fn {p, n} -> %{"pick_no" => n, "player_id" => p} end)
      )
  end

  defp players(prefix \\ "p"), do: for(n <- 1..16, do: "#{prefix}#{n}")

  defp seed_sleeper_adp(order) do
    rows =
      order
      |> Enum.with_index(1)
      |> Enum.map(fn {id, n} ->
        %{"player_id" => id, "stats" => %{"adp_dynasty_2qb" => n * 1.0}}
      end)

    Intel.replace_projections(
      2026,
      rows ++ [%{"player_id" => "nobody", "stats" => %{"adp_dynasty_2qb" => 999}}]
    )
  end

  describe "GET /api/v1/adp" do
    test "counts complete drafts per bucket in the window, against the target", %{conn: conn} do
      startup(1, players())
      startup(2, players())
      startup(3, players(), te_premium: 0.5)
      startup(4, players(), started_at: @old)

      body = conn |> get(~p"/api/v1/adp") |> json_response(200)

      assert body["target"] == 150
      counts = Map.new(body["buckets"], &{&1["bucket"], &1["drafts"]})
      assert counts["startup-sf-no_tep"] == 2
      assert counts["startup-sf-tep"] == 1
      assert counts["rookie-1qb-no_tep"] == 0
      assert map_size(counts) == 8
    end
  end

  describe "GET /api/v1/adp/:bucket" do
    test "gives ADP from this bucket's drafts only, with Sleeper's beside it", %{conn: conn} do
      # Five drafts take players in order; a TE-premium draft and an old
      # draft take them in reverse and must not count.
      for id <- 1..5, do: startup(id, players())
      startup(6, Enum.reverse(players()), te_premium: 1.0)
      startup(7, Enum.reverse(players()), started_at: @old)
      seed_sleeper_adp(players())

      body = conn |> get(~p"/api/v1/adp/startup-sf-no_tep?limit=3") |> json_response(200)

      assert body["drafts"] == 5
      assert body["players"] == 16
      assert body["minDrafts"] == 5

      assert [
               %{"playerId" => "p1", "adp" => 1.0, "n" => 5, "rate" => 1.0, "sleeperAdp" => 1.0},
               %{"playerId" => "p2"},
               %{"playerId" => "p3"}
             ] = body["adp"]

      assert body["sleeper"]["column"] == "adp_dynasty_2qb"
      assert %{"shared" => 16, "spearman" => spearman} = body["sleeper"]["comparison"]
      assert_in_delta spearman, 1.0, 1.0e-12
    end

    test "names where it disagrees with Sleeper", %{conn: conn} do
      for id <- 1..5, do: startup(id, players())
      # Sleeper has p1 and p16 the other way round.
      seed_sleeper_adp(["p16"] ++ Enum.slice(players(), 1..14) ++ ["p1"])

      body = conn |> get(~p"/api/v1/adp/startup-sf-no_tep") |> json_response(200)
      comparison = body["sleeper"]["comparison"]

      assert comparison["spearman"] < 1.0

      assert [%{"playerId" => "p1", "diff" => -15.0}, %{"playerId" => "p16", "diff" => 15.0} | _] =
               comparison["disagreements"]
    end

    test "says what a rookie or TE-premium bucket is compared against", %{conn: conn} do
      body = conn |> get(~p"/api/v1/adp/rookie-sf-tep") |> json_response(200)

      assert body["drafts"] == 0
      assert body["adp"] == []
      assert body["sleeper"]["comparison"] == nil
      assert [rookie, tep] = body["sleeper"]["notes"]
      assert rookie =~ "rookie ADP is empty"
      assert tep =~ "no TE-premium ADP"
    end

    test "is a 404 for a bucket that does not exist, and a 422 for a bad limit", %{conn: conn} do
      conn |> get(~p"/api/v1/adp/startup-3qb-tep") |> json_response(404)
      build_conn() |> get(~p"/api/v1/adp/startup-sf-tep?limit=0") |> json_response(422)
      build_conn() |> get(~p"/api/v1/adp/startup-sf-tep?limit=lots") |> json_response(422)
    end
  end
end
