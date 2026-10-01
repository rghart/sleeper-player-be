defmodule SleeperPlayerApiWeb.LeagueSellJSON do
  @moduledoc "Renders `Intel.SellSignals.analyze/5`, camelCase like the rest of this API."

  alias SleeperPlayerApi.Intel.{Aging, SellSignals}

  def show(%{snapshot: snapshot, teams: teams}) do
    %{
      leagueId: snapshot.league["league_id"],
      season: snapshot.league["season"],
      # The rules the list was drawn under, so a caller can say why a player
      # is or is not on it.
      rules: %{
        ageCutoffs: Aging.cutoffs(),
        minValue: SellSignals.min_value(),
        buyerMaxZ: SellSignals.buyer_max_z(),
        valueSource: "ktc"
      },
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
      candidates:
        Enum.map(team.candidates, fn c ->
          %{
            playerId: c.player_id,
            position: c.position,
            age: c.age,
            cutoff: c.cutoff,
            value: c.value,
            buyers:
              Enum.map(c.buyers, fn b ->
                %{
                  rosterId: b.roster_id,
                  name: b.name,
                  tier: b.tier,
                  needGroup: b.need_group,
                  needZ: b.need_z
                }
              end)
          }
        end)
    }
  end
end
