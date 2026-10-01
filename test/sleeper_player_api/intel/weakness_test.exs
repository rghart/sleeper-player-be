defmodule SleeperPlayerApi.Intel.WeaknessTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.{LeagueRankings, Weakness}

  # The power-rankings fixtures carry `expectedGroupStrength`: the frontend's
  # own `groupStrength` run over each fixture's JS-ranked teams (see
  # group_strength.mjs). The port is correct when it reproduces it from the
  # teams this backend ranks out of the same inputs.
  @fixture_dir Path.expand("../../support/fixtures/power_rankings", __DIR__)
  @fixtures @fixture_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".json"))
            |> Enum.sort()

  @tolerance 1.0e-9

  defp rank(fixture) do
    inputs = fixture["inputs"]

    LeagueRankings.rank(%{
      league: inputs["league"],
      rosters: inputs["rosters"],
      users: inputs["users"],
      player_info: inputs["playerInfo"],
      ktc: inputs["inputs"]["ktc"],
      fc: inputs["inputs"]["fc"],
      traded_picks: inputs["inputs"]["tradedPicks"],
      projections: inputs["inputs"]["projections"],
      current_draft_complete: inputs["currentDraftComplete"],
      draft: inputs["draft"]
    })
  end

  for file <- @fixtures do
    @file_name file

    test "reproduces the frontend's group strength for #{Path.rootname(file)}" do
      fixture = @fixture_dir |> Path.join(@file_name) |> File.read!() |> Jason.decode!()
      teams = rank(fixture)

      for {source, expected} <- fixture["expectedGroupStrength"] do
        actual = Weakness.group_strength(teams, String.to_existing_atom(source))

        for {roster_id, groups} <- expected, {group, z} <- groups do
          got = actual[String.to_integer(roster_id)][group]

          assert is_number(got) and abs(got - z) <= @tolerance * max(1, abs(z)),
                 "#{source} roster #{roster_id} #{group}: expected #{z}, got #{inspect(got)}"
        end

        # Same groups, no extras.
        assert Map.new(actual, fn {id, g} -> {to_string(id), Map.keys(g) |> Enum.sort()} end) ==
                 Map.new(expected, fn {id, g} -> {id, Map.keys(g) |> Enum.sort()} end)
      end
    end
  end

  # Three teams, KTC only: a QB and an RB slot, plus a FLEX.
  defp team(roster_id, qb, rb, flex) do
    %{
      roster_id: roster_id,
      name: "T#{roster_id}",
      tiers: %{blend: "middle"},
      lineups: %{
        ktc: %{
          total: qb + rb + flex,
          starters: [
            %{slot: "QB", player_id: "q#{roster_id}", value: qb},
            %{slot: "RB", player_id: "r#{roster_id}", value: rb},
            %{slot: "FLEX", player_id: "f#{roster_id}", value: flex}
          ]
        }
      }
    }
  end

  describe "analyze/1" do
    test "lists deficits weakest first and surpluses strongest first, past the threshold" do
      teams = [team(1, 9000, 1000, 5000), team(2, 5000, 5000, 5000), team(3, 1000, 9000, 5000)]

      [one, two, three] = Weakness.analyze(teams)

      assert one.deficits == ["RB"]
      assert one.surpluses == ["QB"]
      # Average everywhere, and a group with no spread is average, not NaN.
      assert two.deficits == [] and two.surpluses == []
      assert Enum.find(two.groups, &(&1.group == "FLEX")).z == 0
      assert three.deficits == ["QB"] and three.surpluses == ["RB"]
    end

    test "states each group's KTC value against the league median" do
      teams = [team(1, 9000, 1000, 5000), team(2, 5000, 5000, 5000), team(3, 1000, 9000, 4000)]

      qb = Enum.find(hd(Weakness.analyze(teams)).groups, &(&1.group == "QB"))

      assert qb.ktc_value == 9000
      assert qb.league_median_ktc == 5000
      assert Map.keys(qb.by_source) == [:ktc]
    end

    test "only reports the groups the league starts" do
      teams = [team(1, 1, 1, 1), team(2, 2, 2, 2)]

      assert hd(Weakness.analyze(teams)).groups |> Enum.map(& &1.group) == ["QB", "RB", "FLEX"]
    end
  end
end
