defmodule SleeperPlayerApiWeb.AvailabilityController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/drafts/:draft_id/availability?user_id=<n>&at_pick=<n>&limit=<n>`

  See `SleeperPlayerApi.Intel.availability/2` for the full contract —
  `user_id` is required (whose remaining picks are "mine"), `at_pick` and
  `limit` are optional.
  """
  def show(conn, %{"draft_id" => draft_id} = params) do
    with {:ok, user_id} <- require_param(params, "user_id"),
         opts <- [
           user_id: user_id,
           at_pick: to_int(params["at_pick"]),
           limit: to_int(params["limit"])
         ],
         opts <- Enum.reject(opts, fn {_k, v} -> is_nil(v) end),
         {:ok, availability} <- Intel.availability(draft_id, opts) do
      render(conn, :show, availability: availability)
    end
  end

  defp require_param(params, key) do
    case params[key] do
      nil -> {:error, {:missing_param, key}}
      value -> {:ok, value}
    end
  end

  defp to_int(nil), do: nil
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
