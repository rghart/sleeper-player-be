defmodule SleeperPlayerApiWeb.LeagueWeaknessJSON do
  @moduledoc "Renders `Intel.Weakness.analyze/1`, camelCase like the rest of this API."

  alias SleeperPlayerApi.Intel.Weakness

  def show(%{snapshot: snapshot, teams: teams}) do
    %{
      leagueId: snapshot.league["league_id"],
      season: snapshot.league["season"],
      # The z a group must reach, either way, to be listed as a deficit or a
      # surplus, so a caller can tell "not listed" from "average".
      threshold: Weakness.threshold(),
      sources: Enum.map(snapshot.sources, &%{id: &1.id, provider: &1.provider, asOf: &1.as_of}),
      missing: snapshot.missing,
      teams: Enum.map(teams, &team/1)
    }
  end

  defp team(team) do
    %{
      rosterId: team.roster_id,
      name: team.name,
      tier: team.tier,
      deficits: team.deficits,
      surpluses: team.surpluses,
      groups:
        Enum.map(team.groups, fn group ->
          %{
            group: group.group,
            z: group.z,
            bySource: Map.new(group.by_source, fn {id, z} -> {to_string(id), z} end),
            ktcValue: group.ktc_value,
            leagueMedianKtc: group.league_median_ktc
          }
        end)
    }
  end
end
