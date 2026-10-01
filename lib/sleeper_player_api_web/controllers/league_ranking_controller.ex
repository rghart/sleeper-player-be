defmodule SleeperPlayerApiWeb.LeagueRankingController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.{LeagueRankings, MarketSettings, MarketValues, PickHoldings}
  alias SleeperPlayerApi.Tasks.RefreshProjections

  action_fallback SleeperPlayerApiWeb.FallbackController

  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  @doc """
  `GET /api/v1/leagues/:league_id/rankings` — every team's Now and Future
  scores, tier, best lineups and pick holdings (docs/dynasty-engine.md, M1).

  The same rankings the app's Power Rankings panel computes in the browser,
  computed here by `Intel.LeagueRankings` so the app and an agent read one
  implementation.

  Rosters, users, traded picks and drafts are read **live** from Sleeper, for
  the reason `TradeController` gives: a ranking of last night's rosters is a
  ranking of teams that may no longer exist. Values come from what this app
  already stores: KeepTradeCut and pick values from the database, FantasyCalc
  through `MarketValues` (stored slice or cached fetch), projections from
  `player_projections`.

  Only KeepTradeCut is required; without it there is no Future score, so the
  answer is a 503. Every other input only removes a source when it is
  missing, and the response's `missing` says which and why, so a caller never
  mistakes a thinner ranking for a full one.
  """
  def show(conn, %{"league_id" => league_id}) do
    with {:ok, league} <- fetch_league(league_id),
         {:ok, rosters} <- fetch(league_id, "rosters"),
         {:ok, users} <- fetch(league_id, "users"),
         {:ok, drafts} <- fetch(league_id, "drafts") do
      settings = MarketSettings.from_league(league)
      ktc_source = if MarketSettings.superflex?(settings), do: @superflex, else: @one_qb
      season = PickHoldings.to_season(league["season"])

      {ktc, ktc_as_of} = ktc_input(ktc_source)
      {fc, fc_as_of, fc_missing} = fc_input(settings)
      {traded, traded_missing} = traded_input(league_id)
      player_ids = rosters |> Enum.flat_map(&(&1["players"] || [])) |> Enum.uniq()
      {projections, projections_missing} = projections_input(season, player_ids)
      # The app ranks against the league's first draft and calls the season's
      # draft done only when that draft says so; mirrored exactly.
      draft = List.first(drafts)

      teams =
        LeagueRankings.rank(%{
          league: league,
          rosters: rosters,
          users: users,
          player_info: Intel.lineup_players(player_ids),
          ktc: ktc,
          fc: fc,
          traded_picks: traded,
          projections: projections,
          current_draft_complete: draft != nil and draft["status"] == "complete",
          draft: draft
        })

      if teams == nil do
        {:error, :no_dynasty_values}
      else
        render(conn, :show,
          league: league,
          settings: settings,
          teams: teams,
          sources:
            Enum.reject(
              [
                %{id: "ktc", provider: ktc_source, as_of: ktc_as_of},
                fc && %{id: "fc", provider: "fantasycalc", as_of: fc_as_of},
                projections &&
                  %{
                    id: "projections",
                    provider: "sleeper",
                    as_of: Intel.projections_as_of(season)
                  }
              ],
              &(&1 in [nil, false])
            ),
          missing: Enum.reject([fc_missing, traded_missing, projections_missing], &is_nil/1)
        )
      end
    end
  end

  # KeepTradeCut values and pick values, in the `/dynasty-values` shape
  # `LeagueRankings` reads. Nil when nothing is stored, which is the 503.
  defp ktc_input(source) do
    case Intel.player_values(source) do
      [] ->
        {nil, nil}

      values ->
        picks = Intel.draft_pick_values(source)

        {%{
           "values" =>
             Enum.map(values, &%{"playerId" => to_string(&1.player_id), "value" => &1.value}),
           "picks" =>
             Enum.map(
               picks,
               &%{
                 "season" => &1.season,
                 "round" => &1.round,
                 "tier" => &1.tier,
                 "value" => &1.value
               }
             )
         }, newest(values)}
    end
  end

  defp fc_input(settings) do
    case MarketValues.values(settings) do
      {:ok, [_ | _] = values} ->
        {%{
           "values" =>
             Enum.map(values, &%{"playerId" => to_string(&1.player_id), "value" => &1.value})
         }, newest(values), nil}

      {:ok, []} ->
        {nil, nil, %{id: "fc", reason: "no FantasyCalc values are stored for this format yet"}}

      {:error, reason} ->
        {nil, nil, %{id: "fc", reason: "FantasyCalc fetch failed: #{inspect(reason)}"}}
    end
  end

  # Without the traded-picks list every team would be credited with its own
  # picks, a claim nothing can back, so picks are left out rather than
  # guessed and the response says so.
  defp traded_input(league_id) do
    case fetch(league_id, "traded_picks") do
      {:ok, traded} ->
        {traded, nil}

      {:error, reason} ->
        {nil, %{id: "picks", reason: "traded picks unavailable: #{inspect(reason)}"}}
    end
  end

  defp projections_input(nil, _player_ids),
    do: {nil, %{id: "projections", reason: "league has no readable season"}}

  # Only the league's rostered players: the rankings read nothing else, and
  # the full season is ~3,300 rows of stats.
  #
  # Available means the season is stored, not that this league's rows are
  # non-empty: a league that has not drafted rosters nobody, so it reads no
  # rows, and calling that "projections unavailable" would be false - every
  # team simply projects to zero, as it did when the app ranked in the
  # browser.
  defp projections_input(season, player_ids) do
    if RefreshProjections.ensure(season) do
      {Intel.projections(season, player_ids), nil}
    else
      {nil, %{id: "projections", reason: "Sleeper has no #{season} projections"}}
    end
  end

  defp newest(values) do
    values
    |> Enum.map(& &1.as_of)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  end

  defp fetch(league_id, path) do
    case Sleeper.get("/league/#{league_id}/#{path}") do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:ok, _} -> {:error, {:upstream_shape, path}}
      {:error, _} = error -> error
    end
  end

  # Sleeper answers an unknown league id with a 404 and a `null` body
  # (checked 2026-09-30), which is the caller's mistake rather than an
  # upstream failure, so it is a 404 here too and not a 502.
  defp fetch_league(league_id) do
    case Sleeper.get("/league/#{league_id}") do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:ok, _} -> {:error, {:upstream_shape, "league"}}
      {:error, _} = error -> error
    end
  end
end
