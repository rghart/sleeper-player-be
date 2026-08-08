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
  defp always(p), do: fn _training, _board -> fn _player, _from, _to, _gone -> p end end

  # Most cases here are about the scoring rules, which apply to both
  # populations; they read the unfiltered one. The `contested` split has its
  # own describe block below.
  defp run_all(drafts, builder, opts), do: Calibration.run(drafts, builder, opts).all

  describe "censoring — the bug that hid inside the old harness" do
    test "a draft that ended before the target pick is not scored at all" do
      # Both drafts end at 4, so nothing can be asked about pick 5+. Player A
      # is never taken in either. The broken version counted him as having
      # survived to every pick in the grid, which is evidence it does not have.
      drafts = [draft(4.0, [{2.0, "B"}]), draft(4.0, [{3.0, "B"}])]

      result = run_all(drafts, always(0.5), deltas: [10], players: ["A"])

      assert result.n == 0, "a draft that never reached the target must leave the risk set"
    end

    test "the same pair is scored once the draft does reach the target" do
      drafts = [draft(12.0, [{2.0, "B"}]), draft(12.0, [{3.0, "B"}])]

      result = run_all(drafts, always(0.5), deltas: [10], ks: [1], players: ["A"])

      # k=1, target=11, both drafts reached 12 -> one observation each.
      assert result.n == 2
    end
  end

  describe "conditioning" do
    test "a player already gone at k is not asked about from k" do
      # Taken at 2. From k=3 onwards the question "given he is on the board at
      # 3" does not apply to him at all.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}])]

      result = run_all(drafts, always(0.5), deltas: [1], ks: [3], players: ["A"])

      assert result.n == 0
    end

    test "a player taken exactly at k still counts as available at k" do
      # The hazard at k is the chance he goes *at* k, so he is on the board
      # when that pick starts. Off by one here and every prediction is scored
      # against the wrong risk set.
      drafts = [draft(12.0, [{3.0, "A"}]), draft(12.0, [{3.0, "A"}])]

      result = run_all(drafts, always(0.5), deltas: [1], ks: [3], players: ["A"])

      assert result.n == 2
      # He was taken at 3, so he did not last to 4.
      assert Enum.all?(result.buckets, &(&1.observed == 0.0))
    end
  end

  describe "the observed rate" do
    test "a player who always lasts scores an observed rate of 1.0" do
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = run_all(drafts, always(1.0), deltas: [1], ks: [1], players: ["A"])

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
      result = run_all(drafts, always(1.0), deltas: [2], ks: [1], players: ["A"])

      assert result.n == 2
      assert result.error == 1.0
    end

    test "a 50% call on a coin flip is perfectly calibrated" do
      # Taken at 2 in one draft, at 9 in the other; asked whether he lasts to
      # 5. Leave-one-out means each is scored by a model fit on the other, and
      # the truth is one of each.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = run_all(drafts, always(0.5), deltas: [4], ks: [1], players: ["A"])

      assert result.n == 2
      assert [%{observed: 0.5, mean_predicted: 0.5}] = result.buckets
      assert result.error == 0.0
    end
  end

  describe "leave-one-draft-out" do
    test "each draft is scored by a model that never saw it" do
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{3.0, "A"}]), draft(12.0, [{4.0, "A"}])]

      seen =
        run_all(
          drafts,
          fn training, _board ->
            # Record how big the training set was, as the "probability".
            fn _player, _from, _to, _gone -> length(training) / 10 end
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

      result = run_all(drafts, always(1.0), deltas: [1], ks: [1], players: ["A"])

      assert [%{bucket: 0.9}] = result.buckets
    end

    test "weights each bucket by how many observations landed in it" do
      # Player A is asked about twice as often as B by using two ks for A.
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result =
        run_all(
          drafts,
          fn _, _ -> fn _player, from, _to, _gone -> if from == 1, do: 1.0, else: 0.0 end end,
          deltas: [1],
          ks: [1, 2, 3],
          players: ["A"]
        )

      # 2 observations predicted 1.0 (right), 4 predicted 0.0 (wrong).
      assert result.n == 6
      assert_in_delta result.error, 4 / 6 * 1.0, 0.0001
    end
  end

  describe "the contested population" do
    # Pinned in code and tested BEFORE either model was measured against it,
    # so the definition cannot be reverse-engineered from a result. Narrowing
    # a population until the answer looks good is how the original harness
    # went wrong (§3g).

    test "keeps the window that straddles where he actually goes" do
      # ADP across the training drafts is 5.0; asking 1 -> 9 straddles it.
      drafts = [
        draft(12.0, [{5.0, "A"}]),
        draft(12.0, [{5.0, "A"}]),
        draft(12.0, [{5.0, "A"}])
      ]

      result = Calibration.run(drafts, always(0.5), deltas: [8], ks: [1], players: ["A"])

      assert result.all.n == 3
      assert result.contested.n == 3
    end

    test "drops a window that ends well before he ever goes" do
      # ADP 9.0, asked about 1 -> 2: he is certainly still there, and saying so
      # correctly tells you nothing about the estimator.
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [1], ks: [1], players: ["A"])

      assert result.all.n == 2
      assert result.contested.n == 0
    end

    test "drops a window that starts well after he is always gone" do
      # ADP 2.0, asked about 6 -> 7. He is long gone, so the observation is a
      # foregone conclusion in the other direction.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}])]

      # He is not available at k=6 in either draft, so `all` is empty too -
      # conditioning already removes this one. Use a player who survives in one
      # draft to keep an observation alive while still being uncontested.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}]), draft(12.0, [{11.0, "A"}])]
      result = Calibration.run(drafts, always(0.5), deltas: [1], ks: [6], players: ["A"])

      # Only the draft where he lasted past 6 contributes; its training ADP is
      # 2.0, well before the window, so it is not contested.
      assert result.all.n == 1
      assert result.contested.n == 0
    end

    test "a player no training draft ever took is never contested" do
      # No observed ADP means no window to compare against. Counting him would
      # be inventing a claim about where he goes.
      drafts = [draft(12.0, [{2.0, "B"}]), draft(12.0, [{3.0, "B"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [4], ks: [1], players: ["A"])

      assert result.all.n == 2
      assert result.contested.n == 0
    end

    test "the ADP comes from the training corpus, not the held-out draft" do
      # Two drafts take him at 2; the third at 11. When the third is held out,
      # training ADP is 2.0 — so a 9 -> 10 window is not contested even though
      # in *that* draft he went at 11. Leaking the held-out draft into the
      # window would make the harness score its own answer.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}]), draft(12.0, [{11.0, "A"}])]

      result = Calibration.run(drafts, always(0.5), deltas: [1], ks: [9], players: ["A"])

      assert result.all.n == 1, "only the draft where he was still on the board at 9"
      assert result.contested.n == 0
    end
  end

  describe "the Brier score" do
    # Calibration cannot see sharpness; this is what does. Both are reported
    # because a model can be honest and useless.
    test "is 0.0 for a confident predictor that is always right" do
      drafts = [draft(12.0, [{9.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = run_all(drafts, always(1.0), deltas: [1], ks: [1], players: ["A"])

      assert result.brier == 0.0
    end

    test "is 1.0 for a confident predictor that is always wrong" do
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{2.0, "A"}])]

      result = run_all(drafts, always(1.0), deltas: [2], ks: [1], players: ["A"])

      assert result.brier == 1.0
    end

    test "punishes a hedge that calibration is perfectly happy with" do
      # Half survive, half do not, and the model says 50% every time. That is
      # flawless calibration and no information at all — exactly the case
      # `error` alone cannot distinguish from a good model.
      drafts = [draft(12.0, [{2.0, "A"}]), draft(12.0, [{9.0, "A"}])]

      result = run_all(drafts, always(0.5), deltas: [4], ks: [1], players: ["A"])

      assert result.error == 0.0
      assert result.brier == 0.25
    end
  end

  test "an empty corpus is 0 observations rather than a crash" do
    assert %{all: %{n: 0, error: 0.0}, contested: %{n: 0}} = Calibration.run([], always(0.5))
  end
end
