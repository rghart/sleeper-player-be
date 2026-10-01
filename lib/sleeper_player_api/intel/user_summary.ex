defmodule SleeperPlayerApi.Intel.UserSummary do
  @moduledoc """
  One manager's position across every league they are in
  (docs/dynasty-engine.md, M4): per league their tier and window, where they
  are thin, what they hold that is worth most, and who they might sell; and
  across leagues, the players they would sell in one league and keep in
  another.

  Pure. The controller loads each league's `Intel.LeagueSnapshot`; this reads
  them with the same modules the per-league endpoints use (`PowerRankings`,
  `Weakness`, `Aging`, `SellSignals`), so a league's line here says exactly
  what its own endpoints say.

  **Sell here, hold there.** A player rostered in more than one league can be
  right to sell in one and right to keep in another, because the call is
  about the team, not the player. He is a *sell* where `SellSignals` lists him
  (a team that is not contending, him past his age cliff and worth the
  floor), and a *hold* where the team is contending and he starts. Only
  players who are both somewhere are listed: that is the contradiction worth
  seeing in one place.
  """

  alias SleeperPlayerApi.Intel.{Aging, PowerRankings, SellSignals, Weakness}

  @contending ["contender", "all-in"]
  @top_assets 5

  @doc """
  `entries` is one per league, in the order to report them:
  `%{league: sleeper_league_map, result: {:ok, snapshot} | {:skipped, reason} |
  {:error, reason}}`. Returns `%{leagues: [...], cross_league: [...]}`.
  """
  def build(user_id, entries) do
    leagues = Enum.map(entries, &league(user_id, &1))

    %{
      leagues: Enum.map(leagues, &Map.delete(&1, :calls)),
      cross_league: cross_league(leagues)
    }
  end

  defp league(_user_id, %{league: league, result: {:skipped, reason}}),
    do: base(league) |> Map.put(:skipped, reason)

  defp league(_user_id, %{league: league, result: {:error, reason}}),
    do: base(league) |> Map.put(:error, reason)

  defp league(user_id, %{league: league, result: {:ok, snapshot}}) do
    case Enum.find(snapshot.rosters, &mine?(&1, user_id)) do
      nil -> base(league) |> Map.put(:skipped, "you have no roster in this league")
      roster -> analyze(league, snapshot, roster)
    end
  end

  defp analyze(league, snapshot, roster) do
    teams = snapshot.teams
    team = Enum.find(teams, &(&1.roster_id == roster["roster_id"]))
    tier = team.tiers[:blend]
    {lineup, aged_source} = Aging.aging_lineup(team)
    aged_share = Aging.lineup_share(lineup, snapshot.player_info)
    weakness = Weakness.analyze(teams)
    mine = Enum.find(weakness, &(&1.roster_id == team.roster_id))

    sells =
      teams
      |> SellSignals.analyze(
        snapshot.rosters,
        snapshot.player_info,
        snapshot.ktc_values,
        weakness
      )
      |> Enum.find(&(&1.roster_id == team.roster_id))

    sell_ids = if sells, do: Enum.map(sells.candidates, & &1.player_id), else: []

    hold_ids =
      if tier in @contending do
        (team.lineups[:ktc] || %{starters: []}).starters
        |> Enum.map(& &1.player_id)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    base(league)
    |> Map.merge(%{
      roster_id: team.roster_id,
      teams: length(teams),
      tier: tier,
      rank: %{
        now: PowerRankings.ranks_by(teams, & &1.now.blend)[team.roster_id],
        future: PowerRankings.ranks_by(teams, & &1.future)[team.roster_id]
      },
      aging: Aging.aging?(tier, aged_share),
      aged_share: aged_share,
      aged_share_source: aged_source,
      deficits: mine.deficits,
      surpluses: mine.surpluses,
      top_weakness: mine.groups |> Enum.min_by(& &1.z, fn -> nil end) |> weakest(),
      top_assets: top_assets(roster, snapshot),
      picks: %{
        held: length(team.future_detail.picks),
        value: team.future_detail.pick_value,
        net_value: team.picks
      },
      sells: if(sells, do: sells.candidates, else: []),
      missing: snapshot.missing,
      calls: %{sell: sell_ids, hold: hold_ids}
    })
  end

  defp weakest(nil), do: nil
  defp weakest(group), do: %{group: group.group, z: group.z}

  defp top_assets(roster, snapshot) do
    (roster["players"] || [])
    |> Enum.map(&{&1, snapshot.ktc_values[&1]})
    |> Enum.filter(fn {_id, value} -> is_number(value) end)
    |> Enum.sort_by(fn {_id, value} -> value end, :desc)
    |> Enum.take(@top_assets)
    |> Enum.map(fn {id, value} ->
      info = snapshot.player_info[id] || %{}
      %{player_id: id, position: info["position"], age: info["age"], value: value}
    end)
  end

  # Players who are a sell in at least one league and a hold in another.
  defp cross_league(leagues) do
    leagues
    |> Enum.filter(&Map.has_key?(&1, :calls))
    |> Enum.flat_map(fn league ->
      Enum.map(league.calls.sell, &{&1, :sell, league.league_id}) ++
        Enum.map(league.calls.hold, &{&1, :hold, league.league_id})
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {player_id, calls} ->
      sell_in = for {_, :sell, league_id} <- calls, do: league_id
      hold_in = for {_, :hold, league_id} <- calls, do: league_id

      if sell_in != [] and hold_in != [],
        do: [%{player_id: player_id, sell_in: sell_in, hold_in: hold_in}],
        else: []
    end)
    |> Enum.sort_by(& &1.player_id)
  end

  defp base(league) do
    %{
      league_id: league["league_id"],
      name: league["name"],
      status: league["status"],
      league_type: get_in(league, ["settings", "type"])
    }
  end

  defp mine?(roster, user_id) do
    user_id = to_string(user_id)

    to_string(roster["owner_id"]) == user_id or
      user_id in Enum.map(roster["co_owners"] || [], &to_string/1)
  end
end
