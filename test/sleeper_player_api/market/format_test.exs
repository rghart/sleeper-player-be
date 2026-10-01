defmodule SleeperPlayerApi.Market.FormatTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Market.Format

  @now ~U[2026-10-01 12:00:00Z]
  @recent DateTime.to_unix(~U[2026-08-01 00:00:00Z], :millisecond)

  defp draft(overrides) do
    Map.merge(
      %{
        "status" => "complete",
        "start_time" => @recent,
        "metadata" => %{"scoring_type" => "dynasty_ppr"},
        "settings" => %{"player_type" => 0, "teams" => 12, "rounds" => 25}
      },
      overrides
    )
  end

  describe "classify/2" do
    test "a long all-players dynasty draft is a startup, a player_type 1 draft a rookie draft" do
      assert Format.classify(draft(%{}), @now) == {:ok, "startup"}

      rookie = draft(%{"settings" => %{"player_type" => 1, "teams" => 12, "rounds" => 4}})
      assert Format.classify(rookie, @now) == {:ok, "rookie"}
    end

    test "a short all-players draft is neither: a supplemental draft, not a startup" do
      short = draft(%{"settings" => %{"player_type" => 0, "teams" => 12, "rounds" => 5}})
      assert Format.classify(short, @now) == {:skip, :not_rookie_or_startup}
    end

    test "names the rule that rejected a draft" do
      assert Format.classify(draft(%{"status" => "drafting"}), @now) == {:skip, :not_complete}

      assert Format.classify(draft(%{"metadata" => %{"scoring_type" => "2qb"}}), @now) ==
               {:skip, :not_dynasty}

      six = draft(%{"settings" => %{"player_type" => 0, "teams" => 6, "rounds" => 25}})
      assert Format.classify(six, @now) == {:skip, :too_few_teams}

      old = DateTime.to_unix(~U[2025-09-01 00:00:00Z], :millisecond)
      assert Format.classify(draft(%{"start_time" => old}), @now) == {:skip, :outside_window}
    end
  end

  test "superflex is any lineup that can start two quarterbacks" do
    assert Format.qb_slots(%{"settings" => %{"slots_qb" => 1, "slots_super_flex" => 1}}) == 2
    assert Format.bucket("startup", 2, 0.0) == {"startup", "sf", "no_tep"}
    assert Format.bucket("rookie", 1, 0.5) == {"rookie", "1qb", "tep"}
    assert Format.bucket("rookie", nil, nil) == {"rookie", "1qb", "no_tep"}
  end

  test "there are eight buckets, keyed for callers as kind-qb-tep" do
    assert length(Format.buckets()) == 8
    assert Format.bucket_key({"startup", "sf", "tep"}) == "startup-sf-tep"
  end
end
