defmodule SleeperPlayerApiWeb.LeagueRankingJSON do
  @moduledoc """
  Renders `Intel.LeagueRankings` for `GET /api/v1/leagues/:id/rankings`, with
  camelCase keys like the rest of this API.

  Written to be read by a program as much as a screen (an agent will call
  this as a tool): ids beside names, numbers left as numbers, and the
  response says what it rests on - which sources ranked it, how fresh they
  are, which were missing and why, and the format caveats that bear on the
  values - so a caller can hedge without guessing.
  """

  alias SleeperPlayerApi.Intel.{MarketSettings, PowerRankings}

  def show(%{league: league, settings: settings, teams: teams} = assigns) do
    now_rank = PowerRankings.ranks_by(teams, & &1.now.blend)
    future_rank = PowerRankings.ranks_by(teams, & &1.future)

    %{
      leagueId: league["league_id"],
      name: league["name"],
      season: league["season"],
      format: format(league, settings),
      notes: notes(league, settings),
      sources: Enum.map(assigns.sources, &source/1),
      missing: assigns.missing,
      tiers: PowerRankings.tiers(),
      teams:
        Enum.map(teams, fn team ->
          team(team, %{now: now_rank[team.roster_id], future: future_rank[team.roster_id]})
        end)
    }
  end

  defp format(league, settings) do
    %{
      dynasty: settings.dynasty,
      sleeperType: get_in(league, ["settings", "type"]),
      numQbs: settings.num_qbs,
      superflex: MarketSettings.superflex?(settings),
      numTeams: settings.num_teams,
      ppr: settings.ppr,
      tePremium: get_in(league, ["scoring_settings", "bonus_rec_te"]) || 0,
      rosterPositions: league["roster_positions"]
    }
  end

  # The known gaps between this league's format and what the market prices
  # (docs/dynasty-engine.md, "Known format gaps"). Stated, not corrected:
  # correcting them would be inventing numbers the providers do not publish.
  defp notes(league, settings) do
    te_premium = get_in(league, ["scoring_settings", "bonus_rec_te"]) || 0

    [
      settings.num_qbs > 2 &&
        %{
          code: "qb_count_unpriced",
          detail:
            "This league can start #{settings.num_qbs} quarterbacks; KeepTradeCut and " <>
              "FantasyCalc price at most two, so market values understate quarterbacks here."
        },
      te_premium > 0 &&
        %{
          code: "te_premium_unpriced",
          detail:
            "This league adds #{te_premium} per TE reception. Projections score it; " <>
              "KeepTradeCut and FantasyCalc values do not, so they understate tight ends."
        },
      not settings.dynasty &&
        %{
          code: "not_dynasty",
          detail: "Sleeper does not list this as a dynasty league; Future scores assume one."
        }
    ]
    |> Enum.filter(& &1)
  end

  defp source(%{id: id, provider: provider, as_of: as_of}),
    do: %{id: id, provider: provider, asOf: as_of}

  defp team(team, rank) do
    %{
      rosterId: team.roster_id,
      ownerId: team.owner_id,
      name: team.name,
      tier: team.tiers[:blend],
      rank: rank,
      now: string_keys(team.now),
      future: team.future,
      netPickValue: team.picks,
      tiers: string_keys(team.tiers),
      lineups: Map.new(team.lineups, fn {id, lineup} -> {to_string(id), lineup(lineup)} end),
      futureDetail: future_detail(team.future_detail)
    }
  end

  defp lineup(%{starters: starters, total: total}) do
    %{
      total: total,
      starters: Enum.map(starters, &%{slot: &1.slot, playerId: &1.player_id, value: &1.value})
    }
  end

  defp future_detail(detail) do
    %{
      playerValue: detail.player_value,
      pickValue: detail.pick_value,
      netPickValue: detail.net_pick_value,
      total: detail.total,
      picks:
        Enum.map(detail.picks, fn pick ->
          %{
            season: pick.season,
            round: pick.round,
            originalRosterId: pick.original_roster_id,
            value: pick.value,
            basis: pick[:basis],
            tier: pick[:tier]
          }
        end)
    }
  end

  defp string_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
