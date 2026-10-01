defmodule SleeperPlayerApiWeb.LeagueWeaknessController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.{LeagueSnapshot, Weakness}

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/leagues/:league_id/weaknesses` — every team's starting lineup,
  position group by position group, against the rest of the league:
  deficits, surpluses, and the numbers behind them (`Intel.Weakness`).

  Reads the same `Intel.LeagueSnapshot` as `/rankings`, so calling both costs
  one set of Sleeper reads.
  """
  def show(conn, %{"league_id" => league_id}) do
    with {:ok, snapshot} <- LeagueSnapshot.load(league_id) do
      render(conn, :show, snapshot: snapshot, teams: Weakness.analyze(snapshot.teams))
    end
  end
end
