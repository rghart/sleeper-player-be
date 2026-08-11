defmodule SleeperPlayerApiWeb.PlayerValueJSON do
  @moduledoc """
  Renders `SleeperPlayerApi.Intel.player_values/1` — camelCase keys, same
  snake_case-context / camelCase-view split as the other JSON modules here.

  `settings` describes what the numbers are of, and must not be dropped by a
  caller looking to slim the payload. Dynasty superflex values in a 1-QB
  league are not slightly off, they are about a different game, and this
  feature's standing lesson is that the figure is fine and the sentence next
  to it overclaims. The caller needs this to write that sentence.

  It echoes the settings that were *answered*, not the ones that were asked
  for. Those differ whenever a param was omitted and fell back, which is the
  common case - a caller sending only `num_teams` still needs to be told what
  format and scoring it got.
  """

  @doc """
  The value list, plus what the values are of and when they were taken.

  `asOf` is the newest row's timestamp — the freshness of the list as a whole
  is the freshest thing in it, and a caller showing "updated 3 days ago"
  wants that rather than the oldest straggler. `null` for an empty list
  rather than a fabricated now: before the nightly refresh has ever run this
  endpoint answers honestly that it has nothing, which is the same shape as
  `market_rookie_class_entries/1` returning `[]` rather than inventing a
  market read.
  """
  def index(%{values: values, settings: settings}) do
    %{
      settings: %{
        source: "fantasycalc",
        format: if(settings.dynasty, do: "dynasty", else: "redraft"),
        numQbs: settings.num_qbs,
        numTeams: settings.num_teams,
        ppr: settings.ppr
      },
      asOf: newest(values),
      values: Enum.map(values, &value/1)
    }
  end

  # Sleeper ids are strings on the wire, everywhere in this API. They are
  # 19 digits for a user and comfortably inside the safe range for a player,
  # but `IntelJSON` and `ManagerActivityJSON` both string them and a caller
  # keying one map by a number and another by a string finds out at runtime.
  defp value(v) do
    %{
      playerId: to_string(v.player_id),
      value: v.value,
      overallRank: v.overall_rank,
      positionRank: v.position_rank
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
