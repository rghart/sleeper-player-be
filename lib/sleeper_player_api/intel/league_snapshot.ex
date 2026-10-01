defmodule SleeperPlayerApi.Intel.LeagueSnapshot do
  @moduledoc """
  Everything the league analyses rest on, loaded once: the league as Sleeper
  has it right now, the values and projections this app stores, and the
  ranking computed from them (docs/dynasty-engine.md, M2).

  `/rankings`, `/weaknesses` and `/sells` all start here. Each needs the same
  live Sleeper reads and the same ranking, and an agent answering one
  question may call several of them in a row, so a successful snapshot is
  kept for a minute in `LeagueSnapshotCache`.

  This is the one impure piece. It fetches; `LeagueRankings`, `Weakness` and
  `SellSignals` decide.

  Rosters, users, traded picks and drafts are read **live** from Sleeper, for
  the reason `TradeController` gives: an analysis of last night's rosters is
  an analysis of teams that may no longer exist. Values come from what this
  app already stores: KeepTradeCut and pick values from the database,
  FantasyCalc through `MarketValues`, projections from `player_projections`.

  Only KeepTradeCut is required; without it there is no Future score and the
  answer is `{:error, :no_dynasty_values}`. Every other input only removes a
  source when it is missing, and `missing` says which and why.
  """

  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel

  alias SleeperPlayerApi.Intel.{
    LeagueRankings,
    LeagueSnapshotCache,
    MarketSettings,
    MarketValues,
    PickHoldings,
    Projections
  }

  alias SleeperPlayerApi.Tasks.RefreshProjections

  @one_qb "keeptradecut:1qb"
  @superflex "keeptradecut:sf"

  @doc """
  The snapshot for `league_id`:

    * `league`, `rosters`, `users`: Sleeper's, as read just now
    * `settings`: `MarketSettings.from_league/1`
    * `player_info`: `Intel.lineup_players/1` for every rostered player
    * `ktc_values`: `%{player_id => value}` under the league's KTC list
    * `teams`: `LeagueRankings.rank/1`'s output
    * `sources`, `missing`: what the ranking rests on, and what it lacked

  Errors: `{:error, :not_found}` for a league Sleeper does not know,
  `{:error, :no_dynasty_values}` with no KTC values stored, and the Sleeper
  client's errors for a failed read.
  """
  @spec load(String.t()) :: {:ok, map} | {:error, term}
  def load(league_id) do
    case LeagueSnapshotCache.get(league_id) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      :miss ->
        with {:ok, snapshot} <- build(league_id) do
          LeagueSnapshotCache.put(league_id, snapshot)
          {:ok, snapshot}
        end
    end
  end

  defp build(league_id) do
    # KTC is checked straight after the league, before the other reads:
    # without it nothing can be ranked, so there is no point spending rosters,
    # users, drafts, FantasyCalc, traded picks and projections on the league.
    with {:ok, league} <- fetch_league(league_id),
         settings = MarketSettings.from_league(league),
         ktc_source = if(MarketSettings.superflex?(settings), do: @superflex, else: @one_qb),
         {:ok, ktc, ktc_as_of} <- require_ktc(ktc_source),
         {:ok, rosters} <- fetch(league_id, "rosters"),
         {:ok, users} <- fetch(league_id, "users"),
         {:ok, drafts} <- fetch(league_id, "drafts") do
      season = PickHoldings.to_season(league["season"])
      {fc, fc_as_of, fc_missing} = fc_input(settings)
      {traded, traded_missing} = traded_input(league_id)
      player_ids = rosters |> Enum.flat_map(&(&1["players"] || [])) |> Enum.uniq()
      {projections, projections_missing} = projections_input(season, player_ids)
      player_info = Intel.lineup_players(player_ids)
      # The app ranked against the league's first draft and called the
      # season's draft done only when that draft said so; mirrored exactly.
      draft = List.first(drafts)

      teams =
        LeagueRankings.rank(%{
          league: league,
          rosters: rosters,
          users: users,
          player_info: player_info,
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
        {:ok,
         %{
           league: league,
           rosters: rosters,
           users: users,
           settings: settings,
           player_info: player_info,
           ktc_values: Map.new(ktc["values"], &{&1["playerId"], &1["value"]}),
           # Kept for the trade finder, which prices picks from the same
           # drafts and traded picks, and measures a contender's lineup on
           # the same projected points the rankings used.
           drafts: drafts,
           traded_picks: traded,
           projected_points:
             projections &&
               Projections.projection_values(projections, league["scoring_settings"]),
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
         }}
      end
    end
  end

  defp require_ktc(source) do
    case ktc_input(source) do
      {nil, _} -> {:error, :no_dynasty_values}
      {ktc, as_of} -> {:ok, ktc, as_of}
    end
  end

  # KeepTradeCut values and pick values, in the `/dynasty-values` shape
  # `LeagueRankings` reads. Nil when nothing is stored.
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
