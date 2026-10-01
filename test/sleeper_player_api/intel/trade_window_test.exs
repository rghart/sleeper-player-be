defmodule SleeperPlayerApi.Intel.TradeWindowTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.TradeWindow

  # A one-QB, one-RB league of three teams. "c" contends, "r" rebuilds, "m"
  # sits in the middle. Values are KTC; projections are season points.
  defp snapshot(opts \\ []) do
    info = fn pos, age -> %{"position" => pos, "fantasy_positions" => [pos], "age" => age} end

    %{
      league: %{"roster_positions" => ["QB", "RB", "BN", "BN"]},
      rosters: [
        %{"roster_id" => 1, "owner_id" => "c", "players" => ~w(cq crb cbench)},
        %{"roster_id" => 2, "owner_id" => "r", "players" => ~w(rq oldrb youngrb)},
        %{"roster_id" => 3, "owner_id" => "m", "players" => ~w(mq mrb)}
      ],
      teams: [
        %{roster_id: 1, tiers: %{blend: "contender"}},
        %{roster_id: 2, tiers: %{blend: "rebuilding"}},
        %{roster_id: 3, tiers: %{blend: "middle"}}
      ],
      player_info: %{
        "cq" => info.("QB", 27),
        "crb" => info.("RB", 23),
        "cbench" => info.("RB", 22),
        "rq" => info.("QB", 25),
        # Past the RB cliff of 26: worth points now, nothing to a rebuild.
        "oldrb" => info.("RB", 28),
        "youngrb" => info.("RB", 21),
        "mq" => info.("QB", 26),
        "mrb" => info.("RB", 24)
      },
      ktc_values: %{
        "cq" => 6000,
        "crb" => 3000,
        "cbench" => 2000,
        "rq" => 2000,
        "oldrb" => 4000,
        "youngrb" => 3000,
        "mq" => 4000,
        "mrb" => 4000
      },
      projected_points:
        Keyword.get(opts, :projected_points, %{
          "cq" => 300,
          "crb" => 150,
          "cbench" => 120,
          "rq" => 200,
          "oldrb" => 220,
          "youngrb" => 100,
          "mq" => 250,
          "mrb" => 180
        })
    }
  end

  defp context(opts \\ []), do: TradeWindow.context(snapshot(opts), %{{2027, 1} => 3000})

  test "a contender gains by what the trade adds to its lineup this season" do
    # The old RB (220 points) replaces the contender's starter (150): +70 on a
    # lineup the league averages (450 + 420 + 430) / 3 = 433.33 points over.
    w = TradeWindow.gain(context(), "c", ["crb"], ["oldrb"], [], [])

    assert w.tier == "contender"
    assert_in_delta w.gain, 70 / (1300 / 3), 1.0e-9
    assert w.gain == w.now
  end

  test "a rebuilder gains by shedding a player past his cliff for one short of it" do
    # The old RB counts for nothing to a rebuild; the incoming young RB for
    # his full 3,000.
    w = TradeWindow.gain(context(), "r", ["oldrb"], ["crb"], [], [])

    assert w.tier == "rebuilding"
    assert w.future > 0
    assert w.gain == w.future
    # Its lineup gets worse (220 points out, 150 in), which a rebuild accepts.
    assert w.now < 0
  end

  test "a pick counts toward the future at the price the finder used" do
    with_pick = TradeWindow.gain(context(), "r", ["oldrb"], [], [], [%{season: 2027, round: 1}])
    without = TradeWindow.gain(context(), "r", ["oldrb"], [], [], [])

    assert with_pick.future > without.future
  end

  test "a team in the middle weighs both" do
    w = TradeWindow.gain(context(), "m", ["mrb"], ["oldrb"], [], [])

    assert w.tier == "middle"
    assert_in_delta w.gain, (w.now + w.future) / 2, 1.0e-12
  end

  test "measures the lineup on KTC when the league has no projections" do
    ctx = context(projected_points: nil)

    assert ctx.now_source == :ktc
    # Old RB (4,000 KTC) for the contender's starter (3,000): a gain now.
    assert TradeWindow.gain(ctx, "c", ["crb"], ["oldrb"], [], []).now > 0
  end

  test "knows nothing about a user with no roster" do
    assert TradeWindow.gain(context(), "stranger", [], [], [], []) == nil
  end
end
