defmodule SleeperPlayerApiWeb.PlayerValueController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.MarketSettings
  alias SleeperPlayerApi.Intel.MarketValues

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/values?dynasty=&num_qbs=&num_teams=&ppr=` — the current market
  values for a league shape, best player first.

  Exists to give the frontend a ranking list it does not have to be given.
  Every other way into that app's rank list starts with a human pasting text,
  which is then guessed at: the name parsed out of a line, the player matched
  fuzzily against 9,000-odd others. This one is keyed by Sleeper id the whole
  way, so nothing is guessed and nothing can be matched to the wrong person.

  ## The params are the point

  A player is priced against a format, and the difference is not a rounding.
  In superflex the most valuable player is a quarterback; in single-QB he is
  a running back. Answering every caller with one slice — which this endpoint
  did when it shipped — hands a 10-team single-QB league a list about a
  different game and says nothing about it.

  Omitted params fall back to the stored slice field by field, so a caller
  that knows only its league size can say only that. `settings` comes back in
  the response describing what was actually answered.

  Anything unparseable or out of range is a 400 rather than a quiet
  substitution: answering a question nobody asked is the specific failure
  this whole feature keeps re-learning.
  """
  def index(conn, params) do
    with {:ok, settings} <- MarketSettings.parse(params),
         {:ok, values} <- MarketValues.values(settings) do
      render(conn, :index, values: values, settings: settings)
    end
  end
end
