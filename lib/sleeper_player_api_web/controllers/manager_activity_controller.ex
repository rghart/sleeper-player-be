defmodule SleeperPlayerApiWeb.ManagerActivityController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/users/:user_id/activity?season=<n>&limit=<n>&types=<a,b>`

  One leaguemate's recent trades, waiver claims and free-agent adds across
  every league they are in, newest first, with `coverage` describing what
  that rests on. See `SleeperPlayerApi.Intel.manager_activity/2`.

  ## Not nested under a league, though the scope doc said it would be

  The scope in plan §6 step 6 proposed
  `/leagues/:league_id/managers/:user_id/activity`. That URL is a lie: the
  data is every transaction of theirs across all 42-odd of their leagues, and
  nothing about the response is scoped to the league in the path. A path
  segment that implies filtering which does not happen is the same species of
  problem as a figure without its sample size, so it is a flat user route.

  If "what did they do in leagues I share with you" is ever wanted, that is a
  genuinely different query and can have its own nested route then.

  A separate endpoint from `/intel` on purpose: the Leaguemates list renders
  thirteen managers from one cheap call, and activity is only wanted for the
  one profile actually opened.
  """
  def show(conn, %{"user_id" => user_id} = params) do
    with {:ok, limit} <- optional_int(params, "limit") do
      activity =
        Intel.manager_activity(user_id,
          season: params["season"],
          types: types(params["types"]),
          limit: limit || 50
        )

      render(conn, :show, activity: activity)
    end
  end

  # Same treatment as `AvailabilityController`: `String.to_integer/1` raises,
  # and `action_fallback` only catches `{:error, _}` *returns*, so parsing
  # with it turns a malformed query param into a 500.
  defp optional_int(params, key) do
    case params[key] do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int}
          _ -> {:error, {:invalid_param, key, value}}
        end
    end
  end

  defp types(nil), do: nil

  defp types(value) when is_binary(value) do
    case value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      types -> types
    end
  end
end
