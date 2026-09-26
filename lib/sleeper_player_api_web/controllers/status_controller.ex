defmodule SleeperPlayerApiWeb.StatusController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.ValueStatus

  @doc """
  `GET /api/v1/status` - whether the market values are current, for the
  app's warning banner. See `Intel.ValueStatus`.

      {
        "sources": [
          {"name": "KeepTradeCut", "asOf": "2026-09-26T12:15:01Z", "maxAgeHours": 3, "stale": false}
        ],
        "unrecognizedPicks": {"count": 0, "examples": []}
      }
  """
  def index(conn, _params) do
    status = ValueStatus.status()

    json(conn, %{
      sources:
        Enum.map(status.sources, fn source ->
          %{
            name: source.name,
            asOf: source.as_of && DateTime.to_iso8601(source.as_of),
            maxAgeHours: source.max_age_hours,
            stale: source.stale
          }
        end),
      unrecognizedPicks: status.unrecognized_picks
    })
  end
end
