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

  describe "per-manager ownership" do
    # One corpus draft in which bob took P1. alice never drafted him but
    # holds him in 3 of her 9 leagues - the trade/waiver case, which is 94%
    # of real ownership and invisible to the corpus.
    setup do
      corpus = [%{l_d: 8.0, picks: [%{norm: 2.0, player_id: "P1", manager: "bob"}]}]

      ownership = %{
        owns: %{{"alice", "P1"} => 3, {"bob", "P1"} => 1},
        leagues: %{"alice" => 9, "bob" => 4, "carol" => 2}
      }

      {:ok, input: base_input(%{corpus: corpus, ownership: ownership, limit: 1})}
    end

    test "lists a manager who owns him but never drafted him", %{input: input} do
      assert {:ok, response} = Availability.build(input)
      assert [target] = response.targets

      assert [alice, bob] = target.per_manager
      assert alice.manager == "alice"
      assert alice.owns == 3
      assert alice.of_leagues == 9
      assert alice.times == 0
      assert alice.adp == nil, "an ownership-only entry has no draft ADP to report"
      assert alice.picks == []

      assert bob.manager == "bob"
      assert bob.times == 1
      assert bob.owns == 1
      assert bob.of_leagues == 4
      assert bob.adp == 2.0
    end

    test "a manager who neither drafted nor owns him is still absent", %{input: input} do
      assert {:ok, response} = Availability.build(input)
      assert [target] = response.targets
      refute Enum.any?(target.per_manager, &(&1.manager == "carol"))
    end

    test "of_leagues is nil for a manager we hold no roster data for" do
      corpus = [%{l_d: 8.0, picks: [%{norm: 2.0, player_id: "P1", manager: "bob"}]}]

      input =
        base_input(%{
          corpus: corpus,
          limit: 1,
          ownership: %{owns: %{}, leagues: %{"alice" => 9}}
        })

      assert {:ok, response} = Availability.build(input)
      assert [%{manager: "bob", owns: 0, of_leagues: nil}] = hd(response.targets).per_manager
    end

    test "with no ownership data at all the draft read is unchanged" do
      corpus = [%{l_d: 8.0, picks: [%{norm: 2.0, player_id: "P1", manager: "bob"}]}]
      input = base_input(%{corpus: corpus, limit: 1})

      assert {:ok, response} = Availability.build(input)

      assert [%{manager: "bob", times: 1, adp: 2.0, owns: 0, of_leagues: nil}] =
               hd(response.targets).per_manager
    end

    # `notable` gates on drafts seen and times taken. An ownership-only entry
    # has times 0, so it can never become the notable claim - which matters
    # because notable prints an ADP delta this entry has no ADP for.
    test "an ownership-only entry can never become the notable claim" do
      corpus =
        for i <- 1..10 do
          %{l_d: 8.0, picks: [%{norm: 2.0, player_id: "P1", manager: "bob"}]}
          |> Map.put(:draft_no, i)
        end

      input =
        base_input(%{
          corpus: corpus,
          limit: 1,
          ownership: %{owns: %{{"alice", "P1"} => 9}, leagues: %{"alice" => 9}}
        })

      assert {:ok, response} = Availability.build(input)
      notable = hd(response.targets).notable
      assert notable == false or notable.manager != "alice"
    end
  end

  describe "at_pick range checking" do
    # Measured against production before this existed: `at_pick=999` on a
    # 48-pick draft was a 200 with an empty board and a target whose
    # `byPick` was empty — honest-looking nonsense the request should never
    # have got past. `at_pick=0` did fail, but only incidentally, as
    # `{:unmapped_slot, 0}` from `PickOwnership` two layers down.
    test "a pick past the end of the draft is refused, not answered with an empty board" do
      input = base_input(%{at_pick: 999})
      assert Availability.build(input) == {:error, {:pick_out_of_range, 999, 8}}
    end

    test "pick 0 is out of range on its own terms, not an unmapped draft slot" do
      input = base_input(%{at_pick: 0})
      assert Availability.build(input) == {:error, {:pick_out_of_range, 0, 8}}
    end

    test "a negative pick is refused" do
      input = base_input(%{at_pick: -5})
      assert Availability.build(input) == {:error, {:pick_out_of_range, -5, 8}}
    end

    test "the first and last real picks are both in range" do
      assert {:ok, first} = Availability.build(base_input(%{at_pick: 1}))
      assert first.current_pick == 1

      assert {:ok, last} = Availability.build(base_input(%{at_pick: 8}))
      assert last.current_pick == 8
      assert last.board == [%{pick: 8, manager: "dave", mine: false, drafts: 0}]
    end

    # `last_pick + 1` is what a finished draft reports as its own
    # `currentPick` (see "a draft that has already finished"), so the
    # response's own value has to be accepted back — otherwise echoing
    # `currentPick` into `at_pick`, which is exactly what the pick selector
    # does, 422s at the end of every draft.
    test "one past the last pick is accepted, because that is what a finished draft reports" do
      assert {:ok, response} = Availability.build(base_input(%{at_pick: 9}))
      assert response.current_pick == 9
      assert response.board == []
    end

    test "two past the last pick is not" do
      assert Availability.build(base_input(%{at_pick: 10})) ==
               {:error, {:pick_out_of_range, 10, 8}}
    end
  end

  describe "a draft that has already finished" do
    # Regression: found by hitting the deployed endpoint against the real
    # District 13 draft, which completed after the corpus was harvested.
    # Every other test here uses a mid-draft board, so nothing caught it.
    #
    # `current_pick` becomes `last_pick + 1` once the final pick is in, and a
    # bare `a..b` range in Elixir silently reverses when a > b. The board came
    # back as [49, 48]: one pick that never existed, one already made.
    setup do
      # 4 teams x 2 rounds = 8 picks, all of them made.
      picks_made = for n <- 1..8, do: %{pick_no: n, player_id: "P#{n}"}
      {:ok, input: base_input(%{picks_made: picks_made})}
    end

    test "reports no remaining picks rather than phantom ones", %{input: input} do
      assert {:ok, response} = Availability.build(input)

      assert response.current_pick == 9
      assert response.last_pick == 8
      assert response.board == []
      assert response.my_picks == []
    end

    test "does not invent a byPick column for a pick that cannot happen", %{input: input} do
      # "P99" is deliberately NOT among the made picks (P1..P8), so it really
      # is still a candidate and `targets` is non-empty — otherwise the
      # assertion below would loop over nothing and pass vacuously.
      corpus = [
        %{l_d: 8.0, picks: [%{norm: 2.0, player_id: "P99", manager: "bob"}]}
      ]

      assert {:ok, response} =
               Availability.build(
                 Map.merge(input, %{
                   corpus: corpus,
                   candidate_lookup: %{"P99" => %{name: "Player Ninetynine", position: "WR"}}
                 })
               )

      assert [target] = response.targets

      assert Map.keys(target.by_pick) == [9],
             "expected only the current pick's column, got #{inspect(Map.keys(target.by_pick))}"

      assert target.by_pick[9].base_survival == 1.0
      # No picks left, so nothing can take him: no hazard entries either.
      assert target.hazards == []
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
      assert target.by_pick[1] == %{adj_survival: 1.0, base_survival: 1.0}
    end

    # The shape change that made the response 22x smaller: one hazard entry
    # per pick, instead of a threat list per target pick that re-sent the
    # same prefix every time. See `Estimator.hazards/6`.
    test "hazards carry one entry per pick, stopping at last_pick", %{corpus: corpus} do
      input = base_input(%{corpus: corpus, limit: 1})

      assert {:ok, response} = Availability.build(input)
      target = hd(response.targets)

      # by_pick runs to 9 so the gauntlet can read "survival after pick 8",
      # but no threat can sit at a pick that does not exist.
      assert Enum.map(target.hazards, & &1.pick) == Enum.to_list(1..8)
      assert Enum.all?(target.hazards, &is_float(&1.prob))

      refute Enum.any?(target.hazards, &Map.has_key?(&1, :manager)),
             "manager belongs to the board entry, not to every hazard on every pick"
    end
  end
end
