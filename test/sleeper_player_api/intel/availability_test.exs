defmodule SleeperPlayerApi.Intel.AvailabilityTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.Availability

  defp base_input(overrides \\ %{}) do
    Map.merge(
      %{
        league_name: "Test League",
        draft_id: 1,
        teams: 4,
        rounds: 2,
        draft_type: "linear",
        slot_to_roster_id: %{1 => 1, 2 => 2, 3 => 3, 4 => 4},
        picks_made: [],
        traded_picks: %{},
        roster_to_user: %{1 => 100, 2 => 200, 3 => 300, 4 => 400},
        user_id_to_manager: %{100 => "alice", 200 => "bob", 300 => "carol", 400 => "dave"},
        my_user_id: 100,
        at_pick: nil,
        limit: 20,
        corpus: [],
        candidate_lookup: %{},
        market_rank: %{},
        raw_picks: %{}
      },
      overrides
    )
  end

  describe "board resolution" do
    test "resolves every remaining pick, marks the caller's own, and defaults current_pick to 1 when nothing's been picked" do
      assert {:ok, response} = Availability.build(base_input())

      assert response.current_pick == 1
      assert response.last_pick == 8
      assert response.teams == 4
      assert response.rounds == 2

      assert response.board == [
               %{pick: 1, manager: "alice", mine: true, drafts: 0},
               %{pick: 2, manager: "bob", mine: false, drafts: 0},
               %{pick: 3, manager: "carol", mine: false, drafts: 0},
               %{pick: 4, manager: "dave", mine: false, drafts: 0},
               %{pick: 5, manager: "alice", mine: true, drafts: 0},
               %{pick: 6, manager: "bob", mine: false, drafts: 0},
               %{pick: 7, manager: "carol", mine: false, drafts: 0},
               %{pick: 8, manager: "dave", mine: false, drafts: 0}
             ]

      assert response.my_picks == [1, 5]
    end

    test "current_pick advances past picks already made" do
      input =
        base_input(%{picks_made: [%{pick_no: 1, player_id: "P1"}, %{pick_no: 2, player_id: "P2"}]})

      assert {:ok, response} = Availability.build(input)
      assert response.current_pick == 3
    end

    test "at_pick overrides the live current pick for hypotheticals (plan §3g)" do
      input =
        base_input(%{
          picks_made: [%{pick_no: 1, player_id: "P1"}, %{pick_no: 2, player_id: "P2"}],
          at_pick: 6
        })

      assert {:ok, response} = Availability.build(input)
      assert response.current_pick == 6
      assert response.board |> hd() |> Map.get(:pick) == 6
    end

    test "a traded pick's owner (and mine-ness) reflects the trade, not the original slot" do
      input = base_input(%{traded_picks: %{{1, 2} => 1}})

      assert {:ok, response} = Availability.build(input)
      pick2 = Enum.find(response.board, &(&1.pick == 2))
      assert pick2.manager == "alice"
      assert pick2.mine == true
    end

    test "an unsupported draft type is a hard failure, not a degraded response (plan §3e)" do
      input = base_input(%{draft_type: "auction"})
      assert Availability.build(input) == {:error, {:unsupported_draft_type, "auction"}}
    end

    test "an owner whose roster maps to no known user still appears on the board with a nil manager" do
      input = base_input(%{roster_to_user: %{1 => 100, 2 => 200, 3 => 300}})

      assert {:ok, response} = Availability.build(input)
      pick4 = Enum.find(response.board, &(&1.pick == 4))
      assert pick4.manager == nil
      assert pick4.mine == false
      assert pick4.drafts == 0
    end
  end

  describe "corpus-missing failure behaviour (plan §3e)" do
    test "an empty corpus returns targets: [] and corpusDrafts: 0, never fabricated survival numbers" do
      assert {:ok, response} = Availability.build(base_input())

      assert response.targets == []
      assert response.corpus_drafts == 0
      # the board itself doesn't depend on the corpus at all
      assert length(response.board) == 8
    end
  end

  describe "targets — corpus players still on the board, ordered by league ADP" do
    setup do
      corpus = [
        %{
          l_d: 4.0,
          picks: [
            %{norm: 1.0, player_id: "X", manager: "alice"},
            %{norm: 2.0, player_id: "Y", manager: "bob"},
            %{norm: 3.0, player_id: "Z", manager: "carol"}
          ]
        }
      ]

      %{corpus: corpus}
    end

    test "excludes a player already drafted live, and orders the rest by leagueAdp ascending", %{
      corpus: corpus
    } do
      input = base_input(%{corpus: corpus, picks_made: [%{pick_no: 1, player_id: "X"}]})

      assert {:ok, response} = Availability.build(input)
      ids = Enum.map(response.targets, & &1.id)
      assert ids == ["Y", "Z"]
    end

    test "caps at the given limit", %{corpus: corpus} do
      input = base_input(%{corpus: corpus, limit: 1})

      assert {:ok, response} = Availability.build(input)
      assert length(response.targets) == 1
      assert hd(response.targets).id == "X"
    end

    test "byPick spans current_pick through last_pick + 1 inclusive", %{corpus: corpus} do
      input = base_input(%{corpus: corpus, limit: 1})

      assert {:ok, response} = Availability.build(input)
      target = hd(response.targets)
      keys = target.by_pick |> Map.keys() |> Enum.sort()
      # current_pick 1 .. last_pick 8, +1 for the extra survival-after column
      assert keys == Enum.to_list(1..9)
      assert target.by_pick[1] == %{adj_survival: 1.0, base_survival: 1.0, threats: []}
    end
  end
end
