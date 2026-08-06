defmodule SleeperPlayerApiWeb.IntelController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/leagues/:league_id/intel?season=<n>`

  See `SleeperPlayerApi.Intel.league_intel/2` for the full contract.
  `season` is optional — omitting it reports on every stored draft for this
  league regardless of season.
  """
  def show(conn, %{"league_id" => league_id} = params) do
    intel = Intel.league_intel(league_id, season: params["season"])
    render(conn, :show, intel: intel)
  end
end
