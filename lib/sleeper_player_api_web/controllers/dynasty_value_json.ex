defmodule SleeperPlayerApiWeb.DynastyValueJSON do
  @moduledoc """
  Renders `Intel.values_with_movement/2` and `Intel.draft_pick_values/1` —
  camelCase keys, same split as the other JSON modules here.

  `source` travels with the payload because 1QB and superflex values are
  about different games, and a caller rendering a number without saying which
  slice it came from is the standing failure mode of this whole feature.
  """

  @doc """
  Values with movement, plus rookie pick values.

  `window` and each row's `since` are both present on purpose. The window is
  what was *asked* for; `since` is the day actually compared against, which
  is the most recent close on or before it. They differ whenever a player's
  series has a gap or starts late, and a UI saying "over 30 days" off a
  24-day comparison is overclaiming by exactly the margin nobody would check.
  """
  def index(%{source: source, window: window, values: values, picks: picks}) do
    %{
      source: source,
      window: window,
      asOf: newest(values),
      values: Enum.map(values, &value/1),
      picks: Enum.map(picks, &pick/1)
    }
  end

  # Sleeper ids are strings on the wire everywhere in this API — see
  # `PlayerValueJSON` for why a caller keying one map by number and another
  # by string finds out at runtime.
  defp value(v) do
    %{
      playerId: to_string(v.player_id),
      value: v.value,
      overallRank: v.overall_rank,
      positionRank: v.position_rank,
      # `null`, never 0, when there is nothing to compare against. Flat and
      # unknown are different answers and the UI renders them differently.
      change: v.change,
      changePct: v.change_pct,
      since: v.since
    }
  end

  defp pick(p) do
    %{
      season: p.season,
      round: p.round,
      tier: p.tier,
      value: p.value,
      overallRank: p.overall_rank
    }
  end

  defp newest([]), do: nil

  defp newest(values) do
    values
    |> Enum.map(& &1.as_of)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  end
end
