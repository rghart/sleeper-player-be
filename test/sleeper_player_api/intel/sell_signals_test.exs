defmodule SleeperPlayerApi.Intel.SellSignalsTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.{Aging, SellSignals}

  describe "Aging" do
    test "a player is past the cliff at his position's cutoff, not before" do
      assert Aging.past_cutoff?(%{"position" => "RB", "age" => 26})
      refute Aging.past_cutoff?(%{"position" => "RB", "age" => 25})
      # Same age, different curve: a 30-year-old quarterback is fine.
      refute Aging.past_cutoff?(%{"position" => "QB", "age" => 30})
    end

    test "claims nothing without an age or a cutoff for the position" do
      refute Aging.past_cutoff?(%{"position" => "RB", "age" => nil})
      refute Aging.past_cutoff?(%{"position" => "K", "age" => 40})
      refute Aging.past_cutoff?(nil)
    end

    test "measures the share of lineup value past the cliff" do
      lineup = %{
        total: 10_000,
        starters: [
          %{player_id: "old", value: 4000},
          %{player_id: "young", value: 6000},
          %{player_id: nil, value: 0}
        ]
      }

      info = %{
        "old" => %{"position" => "WR", "age" => 30},
        "young" => %{"position" => "WR", "age" => 23}
      }

      assert Aging.lineup_share(lineup, info) == 0.4
      assert Aging.lineup_share(%{lineup | total: 0}, info) == nil
    end

    test "flags only contenders, at or over the share" do
      assert Aging.aging?("contender", 0.4)
      refute Aging.aging?("all-in", 0.39)
      # Not contending: the question does not arise.
      assert Aging.aging?("rebuilding", 0.9) == nil
    end
  end

  # Team 1 contends and is thin at RB; team 2 contends and is deep at RB but
  # thin at FLEX; team 3 is rebuilding and holds two aging players.
  defp teams do
    [
      %{roster_id: 1, name: "A", tiers: %{blend: "contender"}},
      %{roster_id: 2, name: "B", tiers: %{blend: "all-in"}},
      %{roster_id: 3, name: "C", tiers: %{blend: "rebuilding"}},
      %{roster_id: 4, name: "D", tiers: %{blend: "middle"}}
    ]
  end

  defp weakness do
    [
      %{
        roster_id: 1,
        groups: [%{group: "RB", z: -1.2}, %{group: "WR", z: 0.4}, %{group: "FLEX", z: -0.2}]
      },
      %{
        roster_id: 2,
        groups: [%{group: "RB", z: 0.9}, %{group: "WR", z: -0.3}, %{group: "FLEX", z: -0.6}]
      },
      %{
        roster_id: 3,
        groups: [%{group: "RB", z: 0}, %{group: "WR", z: 0}, %{group: "FLEX", z: 0}]
      },
      %{
        roster_id: 4,
        groups: [%{group: "RB", z: 0}, %{group: "WR", z: 0}, %{group: "FLEX", z: 0}]
      }
    ]
  end

  @rosters [
    %{"roster_id" => 1, "players" => []},
    %{"roster_id" => 2, "players" => []},
    %{"roster_id" => 3, "players" => ["oldrb", "oldwr", "youngrb", "cheapold"]},
    %{"roster_id" => 4, "players" => []}
  ]

  @info %{
    "oldrb" => %{"position" => "RB", "age" => 27},
    "oldwr" => %{"position" => "WR", "age" => 31},
    "youngrb" => %{"position" => "RB", "age" => 22},
    "cheapold" => %{"position" => "RB", "age" => 29}
  }

  @values %{"oldrb" => 4000, "oldwr" => 5000, "youngrb" => 8000, "cheapold" => 300}

  test "lists only non-contenders, with their aging, valuable players, most valuable first" do
    result = SellSignals.analyze(teams(), @rosters, @info, @values, weakness())

    assert Enum.map(result, & &1.roster_id) == [3, 4]
    [rebuilder, middle] = result

    # The young RB is not past his cliff; the cheap one is below the floor.
    assert Enum.map(rebuilder.candidates, & &1.player_id) == ["oldwr", "oldrb"]
    assert middle.candidates == []
  end

  test "pairs each with the contenders thinnest where he would start, neediest first" do
    [rebuilder, _] = SellSignals.analyze(teams(), @rosters, @info, @values, weakness())
    by_id = Map.new(rebuilder.candidates, &{&1.player_id, &1})

    # The RB: team 1 needs one outright; team 2 is deep at RB but would play
    # him at FLEX, where it is thin.
    assert [
             %{roster_id: 1, need_group: "RB", need_z: -1.2},
             %{roster_id: 2, need_group: "FLEX", need_z: -0.6}
           ] = by_id["oldrb"].buyers

    # The WR: team 2 is thinner (its FLEX), team 1 needs no WR but its FLEX
    # is below average too.
    assert Enum.map(by_id["oldwr"].buyers, &{&1.roster_id, &1.need_group}) == [
             {2, "FLEX"},
             {1, "FLEX"}
           ]
  end

  test "a contender above average where he would start is not a buyer" do
    strong =
      Enum.map(weakness(), fn
        %{roster_id: id} = w when id in [1, 2] ->
          %{w | groups: Enum.map(w.groups, &%{&1 | z: 0.8})}

        w ->
          w
      end)

    [rebuilder, _] = SellSignals.analyze(teams(), @rosters, @info, @values, strong)

    assert Enum.all?(rebuilder.candidates, &(&1.buyers == []))
  end
end
