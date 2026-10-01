defmodule SleeperPlayerApiWeb.LeagueSellController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.{LeagueSnapshot, SellSignals, Weakness}

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/leagues/:league_id/sells` — for every team that is not
  contending, the players past their position's age cliff worth selling, and
  the contenders thinnest where each would start (`Intel.SellSignals`).

  Reads the same `Intel.LeagueSnapshot` as `/rankings` and `/weaknesses`.
  """
  def show(conn, %{"league_id" => league_id}) do
    with {:ok, snapshot} <- LeagueSnapshot.load(league_id) do
      weakness = Weakness.analyze(snapshot.teams)

      teams =
        SellSignals.analyze(
          snapshot.teams,
          snapshot.rosters,
          snapshot.player_info,
          snapshot.ktc_values,
          weakness
        )

      render(conn, :show, snapshot: snapshot, teams: teams)
    end
  end
end
