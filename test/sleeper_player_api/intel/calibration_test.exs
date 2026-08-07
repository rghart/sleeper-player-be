defmodule SleeperPlayerApi.Intel.CalibrationTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.Calibration

  # These are hand-computable on purpose. §3g records a version of this harness
  # that scored "not in this draft" as survived regardless of draft length —
  # the same bias the estimator had, so the two cancelled and the naive
  # estimator looked *better* than the corrected one. A harness that is wrong
  # does not fail loudly; it blesses the wrong model. So every rule it applies
  # gets a case with a known answer.

  defp draft(l_d, picks) do
    %{
      l_d: l_d,
      picks: Enum.map(picks, fn {norm, id} -> %{norm: norm, player_id: id, manager: nil} end)
    }
  end

  # A predictor that always says the same thing, so the observed side is the
  # only thing under test.
  defp always(p), do: fn _training -> fn _player, _from, _to -> p end end

  describe "censoring — the bug that hid inside the old harness" do
    test "a draft that ended before the target pick is not scored at all" do
      # Both drafts end at 4, so nothing can be asked about pick 5+. Player A
      # is never taken in either. The broken version counted him as having
      # survived to every pick in the grid, which is evidence it does not have.
      drafts = [draft(4.0, [{2.0, "B"}]), draft(4.0, [{3.0, "B"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [10], players: ["A"])

      assert result.n == 0, "a draft that never reached the target must leave the risk set"
    end

    test "the same pair is scored once the draft does reach the target" do
      drafts = [draft(12.0, [{2.0, "B"}]), draft(12.0, [{3.0, "B"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [10], ks: [1], players: ["A"])

      # k=1, target=11, both drafts reached 12 -> one observation each.
      assert result.n == 2
    end
  end

  describe "conditioning" do
    test "a player already gone at k is not asked about from k" do
      # Taken at 2. From k=3 onwards the question "given he is on the board at
      # 3" does not apply to him at all.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [1], ks: [3], players: ["A"])

      assert result.n == 0
    end

    test "a player taken exactly at k still counts as available at k" do
      # The hazard at k is the chance he goes *at* k, so he is on the board
      # when that pick starts. Off by one here and every prediction is scored
      # against the wrong risk set.
      drafts = [draft(12.0, [{3.0, "A"}]), draft(12.0, [{3.0, "A"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [1], ks: [3], players: ["A"])

      assert result.n == 2
      # He was taken at 3, so he did not last to 4.
      assert Enum.all?(result.buckets, &(&1.observed == 0.0))
    end
  end

  describe "the observed rate" do
    test "a player who always lasts scores an observed rate of 1.0" do
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = Calibration.run(drafts, always(1.0), deltas: [1], ks: [1], players: ["A"])

      assert result.n == 2
      assert [%{observed: 1.0, mean_predicted: 1.0}] = result.buckets
      # Perfectly calibrated: it said 1.0 and got 1.0.
      assert result.error == 0.0
    end

    test "a confident predictor that is always wrong scores an error of 1.0" do
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}])]

      # Says "certain to last" from k=1 to 3; he went at 2 both times, so he
      # was gone by 3. Note the target has to be *past* the pick he went at —
      # taken at 2 means he was still on the board when pick 2 started.
      result = Calibration.run(drafts, always(1.0), deltas: [2], ks: [1], players: ["A"])

      assert result.n == 2
      assert result.error == 1.0
    end

    test "a 50% call on a coin flip is perfectly calibrated" do
      # Taken at 2 in one draft, at 9 in the other; asked whether he lasts to
      # 5. Leave-one-out means each is scored by a model fit on the other, and
      # the truth is one of each.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [4], ks: [1], players: ["A"])

      assert result.n == 2
      assert [%{observed: 0.5, mean_predicted: 0.5}] = result.buckets
      assert result.error == 0.0
    end
  end

  describe "leave-one-draft-out" do
    test "each draft is scored by a model that never saw it" do
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{3.0, "A"}]), draft(12.0, [{4.0, "A"}])]

      seen =
        Calibration.run(
          drafts,
          fn training ->
            # Record how big the training set was, as the "probability".
            fn _player, _from, _to -> length(training) / 10 end
          end,
          deltas: [1],
          ks: [1],
          players: ["A"]
        )

      # Three drafts, each scored against a training set of the other two.
      assert seen.n == 3
      assert [%{mean_predicted: mean}] = seen.buckets
      assert_in_delta mean, 0.2, 0.0001
    end
  end

  describe "bucketing" do
    test "puts a certainty in the top bucket rather than one of its own" do
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = Calibration.run(drafts, always(1.0), deltas: [1], ks: [1], players: ["A"])

      assert [%{bucket: 0.9}] = result.buckets
    end

    test "weights each bucket by how many observations landed in it" do
      # Player A is asked about twice as often as B by using two ks for A.
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result =
        Calibration.run(
          drafts,
          fn _ -> fn _player, from, _to -> if from == 1, do: 1.0, else: 0.0 end end,
          deltas: [1],
          ks: [1, 2, 3],
          players: ["A"]
        )

      # 2 observations predicted 1.0 (right), 4 predicted 0.0 (wrong).
      assert result.n == 6
      assert_in_delta result.error, 4 / 6 * 1.0, 0.0001
    end
  end

  test "an empty corpus is 0 observations rather than a crash" do
    assert %{n: 0, error: 0.0} = Calibration.run([], always(0.5))
  end
end
