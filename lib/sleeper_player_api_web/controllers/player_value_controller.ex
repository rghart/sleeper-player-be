defmodule SleeperPlayerApiWeb.PlayerValueController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  # The only source there is. A path or query segment naming the provider
  # would imply a choice the caller does not have — the same species of lie
  # as `ManagerActivityController`'s rejected nested route. When a second
  # source lands (plan §2 designed `PlayerValueSource` to be swappable), it
  # can become a parameter then, with something real to choose between.
  @source "fantasycalc"

  @doc """
  `GET /api/v1/values` — the current market values, best player first.

  Exists to give the frontend a ranking list it does not have to be given.
  Every other way into that app's rank list starts with a human pasting text,
  which is then guessed at: the name parsed out of a line, the player matched
  fuzzily against 9,000-odd others. This one is keyed by Sleeper id the whole
  way, so nothing is guessed and nothing can be matched to the wrong person.

  ## What this is *not*

  Not "the rankings". It is one provider's dynasty trade values at fixed
  settings — superflex, 12-team, full PPR, pinned in
  `SleeperPlayerApi.Client.FantasyCalc`. In a 1-QB or 10-team league these
  numbers are simply about a different game, and a caller that presents them
  as neutral truth is overclaiming in exactly the way this feature has
  overclaimed four times before. `settings` is in the response so the caller
  can say what it is showing, and it is not decoration.
  """
  def index(conn, _params) do
    render(conn, :index, values: Intel.player_values(@source))
  end
end
