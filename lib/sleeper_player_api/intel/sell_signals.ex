defmodule SleeperPlayerApi.Intel.SellSignals do
  @moduledoc """
  Who a team that is not contending should think about selling, and who
  would want them (docs/dynasty-engine.md, M2).

  A team in Middle, Rebuilding or Stuck gains little from a player whose
  value is about to fall off his position's age cliff (`Intel.Aging`): it is
  not winning with him now, and he will be worth less by the time it is. A
  contender short at his position is the natural buyer, because he helps it
  this season and the decline is a cost it can afford.

  So each candidate is a rostered player past his cutoff and worth at least
  `min_value` on KeepTradeCut, and each comes with the contenders (Contender
  or All-in) whose lineup is below the league average where he would start,
  neediest first.

  "Where he would start" is his position group, or the flex group when that
  is where the buyer is thinner: a running back fills a FLEX hole as well as
  an RB one, and a quarterback fills a superflex. That is read off
  `Intel.Weakness`, so a buyer's need is measured the same way the weakness
  endpoint reports it.

  Pure. This states a fit, not a recommendation to sell: whether to is the
  manager's call, and the agent's job is to explain it.
  """

  alias SleeperPlayerApi.Intel.Aging

  @sellers ["middle", "rebuilding", "stuck"]
  @buyers ["contender", "all-in"]

  @default_min_value 1000
  @default_buyer_max_z 0

  @doc "The least KeepTradeCut value worth listing a candidate for, from config."
  def min_value, do: config(:min_value, @default_min_value)

  @doc "How strong a buyer's group may be, in z, and still count as needing help, from config."
  def buyer_max_z, do: config(:buyer_max_z, @default_buyer_max_z)

  defp config(key, default) do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc """
  One entry per selling team, in roster order: its tier and its candidates,
  most valuable first, each with `buyers`.

  `teams` is `LeagueRankings.rank/1`'s output, `rosters` Sleeper's,
  `player_info` `Intel.lineup_players/1`'s (with `"age"`), `ktc_values`
  `%{player_id => value}`, and `weakness` `Weakness.analyze/1`'s output.
  """
  def analyze(teams, rosters, player_info, ktc_values, weakness) do
    roster_by_id = Map.new(rosters, &{&1["roster_id"], &1})

    need_by_id =
      Map.new(weakness, &{&1.roster_id, Map.new(&1.groups, fn g -> {g.group, g.z} end)})

    buyers = Enum.filter(teams, &(&1.tiers[:blend] in @buyers))

    teams
    |> Enum.filter(&(&1.tiers[:blend] in @sellers))
    |> Enum.map(fn team ->
      candidates =
        (roster_by_id[team.roster_id]["players"] || [])
        |> Enum.map(&{&1, player_info[&1], ktc_values[&1]})
        |> Enum.filter(fn {_id, info, value} ->
          Aging.past_cutoff?(info) and is_number(value) and value >= min_value()
        end)
        |> Enum.sort_by(fn {_id, _info, value} -> value end, :desc)
        |> Enum.map(fn {id, info, value} ->
          %{
            player_id: id,
            position: info["position"],
            age: info["age"],
            cutoff: Aging.cutoffs()[info["position"]],
            value: value,
            buyers: buyers_for(info["position"], buyers, need_by_id)
          }
        end)

      %{
        roster_id: team.roster_id,
        name: team.name,
        tier: team.tiers[:blend],
        candidates: candidates
      }
    end)
  end

  # Contenders below the line where this player would start, neediest first.
  # The need is the thinner of his own group and the flex group.
  defp buyers_for(position, buyers, need_by_id) do
    buyers
    |> Enum.flat_map(fn team ->
      needs = need_by_id[team.roster_id] || %{}

      [position, "FLEX"]
      |> Enum.filter(&Map.has_key?(needs, &1))
      |> Enum.min_by(&needs[&1], fn -> nil end)
      |> case do
        nil ->
          []

        group ->
          z = needs[group]

          if z <= buyer_max_z(),
            do: [
              %{
                roster_id: team.roster_id,
                name: team.name,
                tier: team.tiers[:blend],
                need_group: group,
                need_z: z
              }
            ],
            else: []
      end
    end)
    |> Enum.sort_by(& &1.need_z)
  end
end
