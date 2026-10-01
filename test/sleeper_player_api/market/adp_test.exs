defmodule SleeperPlayerApi.Market.AdpTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Market.Adp

  # Five drafts. "a" goes 1st or 2nd every time; "b" 2nd or 3rd; "c" only in
  # four of them; "d" in two - below the five-draft floor.
  defp drafts do
    [
      [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}],
      [{"a", 2}, {"b", 3}, {"c", 1}],
      [{"a", 1}, {"b", 2}, {"c", 5}, {"d", 3}],
      [{"a", 1}, {"b", 3}, {"c", 2}],
      [{"a", 2}, {"b", 2}]
    ]
    |> Enum.with_index()
    |> Enum.map(fn {picks, i} ->
      %{id: i, picks: Enum.map(picks, fn {p, n} -> %{player_id: p, pick_no: n} end)}
    end)
  end

  describe "compute/1" do
    test "averages each player's picks across the drafts that took him, earliest first" do
      [a, b] = Adp.compute(drafts())

      assert %{player_id: "a", adp: 1.4, median: 1.0, min: 1, max: 2, n: 5, rate: 1.0} = a
      assert %{player_id: "b", adp: 2.4, median: 2.0, n: 5} = b
      assert_in_delta a.stdev, :math.sqrt(0.24), 1.0e-12
    end

    test "leaves out a player taken in fewer drafts than the floor" do
      ids = drafts() |> Adp.compute() |> Enum.map(& &1.player_id)

      # "c" went in four drafts and "d" in two; the floor is five.
      assert ids == ["a", "b"]
    end

    test "reports how often a player is taken, so a rarely-taken one can be read for what he is" do
      # Five more drafts that ignore "a": his ADP is unchanged, his rate halves.
      empty = for i <- 10..14, do: %{id: i, picks: [%{player_id: "z", pick_no: 1}]}

      a = drafts() |> Kernel.++(empty) |> Adp.compute() |> Enum.find(&(&1.player_id == "a"))

      assert a.adp == 1.4
      assert a.rate == 0.5
    end

    test "counts a player once per draft even if a payload repeats him" do
      dupes =
        Enum.map(drafts(), fn d -> %{d | picks: d.picks ++ [%{player_id: "a", pick_no: 99}]} end)

      assert hd(Adp.compute(dupes)).adp == 1.4
    end
  end

  describe "compare/3" do
    defp ours(ids),
      do: ids |> Enum.with_index(1) |> Enum.map(fn {id, i} -> %{player_id: id, adp: i * 1.0} end)

    test "is 1 for the same order and -1 for the reverse" do
      ids = ~w(a b c d e)

      assert_in_delta Adp.compare(ours(ids), Map.new(Enum.with_index(ids, 1))).spearman,
                      1.0,
                      1.0e-12

      reversed = Map.new(Enum.with_index(Enum.reverse(ids), 1))
      assert_in_delta Adp.compare(ours(ids), reversed).spearman, -1.0, 1.0e-12
    end

    test "matches Spearman's rho worked by hand" do
      # Ranks 1..5 against 2,1,4,3,5: sum of squared differences is 4, so
      # rho = 1 - 6*4 / (5*24) = 0.8.
      sleeper = %{"a" => 2, "b" => 1, "c" => 4, "d" => 3, "e" => 5}

      result = Adp.compare(ours(~w(a b c d e)), sleeper)

      assert_in_delta result.spearman, 0.8, 1.0e-12
      assert result.shared == 5
      assert result.mean_abs_rank_diff == 0.8
    end

    test "names the biggest disagreements, positive where the market here is later" do
      sleeper = %{"a" => 5, "b" => 2, "c" => 3, "d" => 4, "e" => 1}

      [first, second | _] = Adp.compare(ours(~w(a b c d e)), sleeper).disagreements

      # "a" goes 1st here and 5th on Sleeper; "e" the opposite.
      assert %{player_id: "a", our_rank: 1.0, sleeper_rank: 5.0, diff: -4.0} = first
      assert %{player_id: "e", diff: 4.0} = second
    end

    test "compares only players both lists have, and gives up below three" do
      sleeper = %{"a" => 1, "b" => 2, "x" => 3}

      assert Adp.compare(ours(~w(a b c)), sleeper) == nil
    end
  end
end
