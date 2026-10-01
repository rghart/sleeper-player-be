defmodule SleeperPlayerApiWeb.LeagueRankingController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.LeagueSnapshot

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/leagues/:league_id/rankings` — every team's Now and Future
  scores, tier, contend/rebuild window, best lineups and pick holdings
  (docs/dynasty-engine.md, M1-M2).

  The same rankings the app's Power Rankings panel used to compute in the
  browser, computed by `Intel.LeagueRankings` from an `Intel.LeagueSnapshot`
  so the app and an agent read one implementation. See the snapshot for what
  is read live, what is stored, and what happens when an input is missing.
  """
  def show(conn, %{"league_id" => league_id}) do
    with {:ok, snapshot} <- LeagueSnapshot.load(league_id) do
      render(conn, :show, snapshot)
    end
  end
end
