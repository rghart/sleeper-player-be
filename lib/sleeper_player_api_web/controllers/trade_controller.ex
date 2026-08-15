defmodule SleeperPlayerApiWeb.TradeController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.PickHoldings
  alias SleeperPlayerApi.Intel.TradeFinder

  action_fallback SleeperPlayerApiWeb.FallbackController

  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  @doc """
  `GET /api/v1/leagues/:league_id/trades?user_id=&superflex=` — trades the
  asking manager and each of their leaguemates might both want.

  Rosters, users and league settings are read **live** from Sleeper rather
  than from the corpus, for the same reason `availability/2` does it: a trade
  suggestion built on last night's roster is a suggestion about a team that
  no longer exists, and this is the one place in the app where being a day
  stale changes the answer completely.

  `superflex` picks which KeepTradeCut price list to use, and it is not
  cosmetic — see `DynastyValueController`. Defaults to superflex.

  A manager with no roster in the league is a 404 rather than an empty list:
  "you are not in this league" and "no trades were found" are different
  answers and must not render the same.
  """
  def index(conn, %{"league_id" => league_id} = params) do
    source = if params["superflex"] in ["false", "0"], do: @one_qb, else: @superflex

    with {:ok, user_id} <- require_user(params["user_id"]),
         {:ok, rosters} <- fetch(league_id, "rosters"),
         {:ok, users} <- fetch(league_id, "users"),
         {:ok, league} <- fetch_league(league_id),
         {:ok, drafts} <- fetch(league_id, "drafts"),
         {:ok, traded} <- fetch(league_id, "traded_picks"),
         {:ok, mine, others} <- split(rosters, users, user_id) do
      values = value_lookup(source)
      pick_values = pick_value_lookup(source)

      # Picks are keyed to rosters by Sleeper and to managers by this app, so
      # the holdings are re-keyed by owning user before the finder sees them.
      owners = Map.new(rosters, fn r -> {r["roster_id"], to_string(r["owner_id"])} end)

      holdings =
        PickHoldings.build(drafts, traded, priced_seasons(pick_values),
          rounds: draft_rounds(league),
          roster_ids: Map.keys(owners)
        )

      picks_by_user =
        Map.new(holdings, fn {roster_id, picks} -> {Map.get(owners, roster_id), picks} end)

      opts = %{
        positions: Intel.player_positions(roster_player_ids(rosters)),
        values: values,
        starters: TradeFinder.starters(league["roster_positions"]),
        # The board's most valuable asset sets TradeValue's scale. Taken from
        # the price list rather than hardcoded, so it moves with the market.
        top_value: values |> Map.values() |> Enum.max(fn -> 0 end),
        pick_values: pick_values,
        picks_by_user: picks_by_user,
        my_picks: Map.get(picks_by_user, user_id, [])
      }

      render(conn, :index,
        source: source,
        league_id: league_id,
        suggestions: TradeFinder.find(mine, others, opts),
        depth: TradeFinder.depth(mine.player_ids, opts),
        starters: opts.starters,
        # The number depth is actually compared against. Sending `starters`
        # without it would show the caller the wrong yardstick — starters no
        # longer decide deep or thin.
        league_average: TradeFinder.league_average([mine | others], opts)
      )
    end
  end

  defp require_user(nil), do: {:error, {:missing_param, :user_id}}
  defp require_user(""), do: {:error, {:missing_param, :user_id}}
  defp require_user(user_id), do: {:ok, to_string(user_id)}

  defp fetch(league_id, path) do
    case Sleeper.get("/league/#{league_id}/#{path}") do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:ok, _} -> {:error, {:upstream_shape, path}}
      {:error, _} = error -> error
    end
  end

  defp fetch_league(league_id) do
    case Sleeper.get("/league/#{league_id}") do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _} -> {:error, {:upstream_shape, "league"}}
      {:error, _} = error -> error
    end
  end

  # One roster per manager, shaped for the finder. A roster with no owner is
  # dropped rather than becoming a trade partner nobody can message.
  defp split(rosters, users, user_id) do
    names = Map.new(users, fn u -> {to_string(u["user_id"]), u["display_name"]} end)

    shaped =
      rosters
      |> Enum.filter(& &1["owner_id"])
      |> Enum.map(fn roster ->
        owner = to_string(roster["owner_id"])

        %{
          user_id: owner,
          display_name: Map.get(names, owner),
          player_ids: Enum.map(roster["players"] || [], &to_string/1)
        }
      end)

    case Enum.split_with(shaped, &(&1.user_id == user_id)) do
      {[mine | _], others} -> {:ok, mine, others}
      {[], _} -> {:error, {:not_in_league, user_id}}
    end
  end

  defp roster_player_ids(rosters) do
    rosters
    |> Enum.flat_map(&(&1["players"] || []))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  # Mid tier throughout: a Sleeper traded pick carries a season and a round
  # and nothing else, and which tier it becomes depends on where that roster
  # finishes. Mid is the honest single answer — see the `draft_pick_values`
  # migration for why all three are stored rather than one being chosen at
  # write time.
  @assumed_tier "mid"

  defp pick_value_lookup(source) do
    source
    |> Intel.draft_pick_values()
    |> Enum.filter(&(&1.tier == @assumed_tier))
    |> Map.new(fn p -> {{p.season, p.round}, p.value} end)
  end

  defp priced_seasons(pick_values) do
    pick_values |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  # Sleeper puts the rookie-draft round count on the league settings; four is
  # the common default and what KeepTradeCut prices out to.
  defp draft_rounds(league), do: get_in(league, ["settings", "draft_rounds"]) || 4

  defp value_lookup(source) do
    source
    |> Intel.player_values()
    |> Map.new(fn v -> {to_string(v.player_id), v.value} end)
  end
end
