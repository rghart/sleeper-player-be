defmodule SleeperPlayerApi.Intel.PickOwnershipTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.PickOwnership

  describe "round_of/2 and slot_of/3 — linear" do
    test "round is 1-indexed ceil(pick/teams)" do
      assert PickOwnership.round_of(1, 12) == 1
      assert PickOwnership.round_of(12, 12) == 1
      assert PickOwnership.round_of(13, 12) == 2
      assert PickOwnership.round_of(35, 12) == 3
      assert PickOwnership.round_of(37, 12) == 4
    end

    test "linear slot never reverses across rounds" do
      assert PickOwnership.slot_of(1, 12, "linear") == {:ok, 1}
      assert PickOwnership.slot_of(12, 12, "linear") == {:ok, 12}
      # round 2 starts back at slot 1, not 12 (that's snake's job)
      assert PickOwnership.slot_of(13, 12, "linear") == {:ok, 1}
      assert PickOwnership.slot_of(35, 12, "linear") == {:ok, 11}
    end
  end

  describe "slot_of/3 — snake" do
    test "reverses on even rounds" do
      # round 1 (odd): forward
      assert PickOwnership.slot_of(1, 12, "snake") == {:ok, 1}
      assert PickOwnership.slot_of(12, 12, "snake") == {:ok, 12}
      # round 2 (even): reversed — pick 13 is slot 12, pick 24 is slot 1
      assert PickOwnership.slot_of(13, 12, "snake") == {:ok, 12}
      assert PickOwnership.slot_of(24, 12, "snake") == {:ok, 1}
      # round 3 (odd): forward again
      assert PickOwnership.slot_of(25, 12, "snake") == {:ok, 1}
    end
  end

  describe "slot_of/3 — unsupported draft type fails loudly" do
    test "auction (and anything else) is a hard error, not a guess" do
      assert PickOwnership.slot_of(5, 12, "auction") ==
               {:error, {:unsupported_draft_type, "auction"}}
    end
  end

  describe "resolve_roster/5" do
    setup do
      slot_to_roster_id = for slot <- 1..12, into: %{}, do: {slot, slot}
      %{slot_to_roster_id: slot_to_roster_id}
    end

    test "no trade — pick resolves to the original slot's roster", %{
      slot_to_roster_id: slot_to_roster_id
    } do
      assert PickOwnership.resolve_roster(1, 12, "linear", slot_to_roster_id, %{}) == {:ok, 1}
    end

    test "a traded pick resolves to the new roster, not the original slot's", %{
      slot_to_roster_id: slot_to_roster_id
    } do
      # pick 1 is round 1, slot 1 -> original roster 1. Roster 1's round-1
      # pick was traded to roster 9.
      traded = %{{1, 1} => 9}

      assert PickOwnership.resolve_roster(1, 12, "linear", slot_to_roster_id, traded) ==
               {:ok, 9}
    end

    test "propagates the unsupported-type error", %{slot_to_roster_id: slot_to_roster_id} do
      assert PickOwnership.resolve_roster(1, 12, "snek", slot_to_roster_id, %{}) ==
               {:error, {:unsupported_draft_type, "snek"}}
    end

    test "an empty slot_to_roster_id is an error, not a KeyError crash" do
      # Regression: a real production draft had `slot_to_roster_id: %{}`
      # (the crawler's own `/user/:id/drafts/nfl/:season` listing call
      # never returns that field — see `SleeperPlayerApi.Intel.
      # fetch_slot_to_roster_id/1`). `Map.fetch!/2` turned that into an
      # uncaught `KeyError` and a 500; this must come back as a tagged
      # error instead.
      assert PickOwnership.resolve_roster(1, 12, "linear", %{}, %{}) ==
               {:error, {:unmapped_slot, 1}}
    end

    test "a partial slot_to_roster_id errors only for the slot that's actually missing" do
      partial = %{1 => 1, 2 => 2}

      assert PickOwnership.resolve_roster(1, 12, "linear", partial, %{}) == {:ok, 1}

      assert PickOwnership.resolve_roster(3, 12, "linear", partial, %{}) ==
               {:error, {:unmapped_slot, 3}}
    end
  end

  describe "resolve_board/5 — the §4f acceptance case" do
    test "atekipp owns both pick 35 and pick 37 once trades are applied" do
      teams = 12
      slot_to_roster_id = %{11 => 5, 1 => 9, 12 => 3, 2 => 2}

      # round 3 roster 5's pick -> roster 9 (atekipp); round 4 roster 9's
      # OWN pick stays roster 9 (atekipp already owned it); round 4 roster
      # 2 stays roster 2; round 3 roster 3 stays roster 3.
      traded = %{{3, 5} => 9}

      assert {:ok, board} =
               PickOwnership.resolve_board(35..38, teams, "linear", slot_to_roster_id, traded)

      assert board == [
               %{pick: 35, roster_id: 9},
               %{pick: 36, roster_id: 3},
               %{pick: 37, roster_id: 9},
               %{pick: 38, roster_id: 2}
             ]
    end

    test "short-circuits on the first unresolved pick rather than resolving a mixed board" do
      assert PickOwnership.resolve_board(1..5, 12, "auction", %{}, %{}) ==
               {:error, {:unsupported_draft_type, "auction"}}
    end
  end
end
