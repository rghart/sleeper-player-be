defmodule SleeperPlayerApiWeb.UserSummaryJSON do
  @moduledoc "Renders `Intel.UserSummary`, camelCase like the rest of this API."

  def show(%{account: account, season: season, summary: summary}) do
    %{
      user: %{
        userId: account["user_id"],
        username: account["username"],
        displayName: account["display_name"]
      },
      season: season,
      leagues: Enum.map(summary.leagues, &league/1),
      crossLeague:
        Enum.map(summary.cross_league, fn p ->
          %{playerId: p.player_id, sellIn: p.sell_in, holdIn: p.hold_in}
        end)
    }
  end

  defp league(%{skipped: reason} = l), do: Map.put(base(l), :skipped, reason)
  defp league(%{error: reason} = l), do: Map.put(base(l), :error, reason)

  defp league(l) do
    Map.merge(base(l), %{
      rosterId: l.roster_id,
      teams: l.teams,
      tier: l.tier,
      rank: l.rank,
      aging: l.aging,
      agedShare: l.aged_share,
      agedShareSource: l.aged_share_source && to_string(l.aged_share_source),
      topWeakness: l.top_weakness,
      deficits: l.deficits,
      surpluses: l.surpluses,
      topAssets:
        Enum.map(
          l.top_assets,
          &%{playerId: &1.player_id, position: &1.position, age: &1.age, value: &1.value}
        ),
      picks: %{held: l.picks.held, value: l.picks.value, netValue: l.picks.net_value},
      sells:
        Enum.map(l.sells, fn c ->
          %{
            playerId: c.player_id,
            position: c.position,
            age: c.age,
            value: c.value,
            buyers:
              Enum.map(
                c.buyers,
                &%{
                  rosterId: &1.roster_id,
                  name: &1.name,
                  needGroup: &1.need_group,
                  needZ: &1.need_z
                }
              )
          }
        end),
      missing: l.missing
    })
  end

  defp base(l),
    do: %{leagueId: l.league_id, name: l.name, status: l.status, leagueType: l.league_type}
end
