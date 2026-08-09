defmodule SleeperPlayerApiWeb.AvailabilityController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/drafts/:draft_id/availability?user_id=<n>&at_pick=<n>&limit=<n>&player_ids=<a,b,c>`

  See `SleeperPlayerApi.Intel.availability/2` for the full contract —
  `user_id` is required (whose remaining picks are "mine"), `at_pick`,
  `limit` and `player_ids` are optional.

  `at_pick` is validated in two stages, because only the second knows the
  draft: this module rejects anything non-numeric, and
  `SleeperPlayerApi.Intel.Availability.build/1` rejects a number outside
  the draft's own picks. Both come back as a 422 via the fallback.

  `player_ids` is a comma-separated list of Sleeper player ids and
  restricts `targets` to those players (plan §6 step 3 — the frontend
  sends its rank list). A blank value is treated as absent rather than as
  "no players": `?player_ids=` is what an empty rank list serialises to,
  and answering it with zero targets would be indistinguishable from a
  corpus with no reads.
  """
  def show(conn, %{"draft_id" => draft_id} = params) do
    with {:ok, user_id} <- require_param(params, "user_id"),
         {:ok, at_pick} <- optional_int(params, "at_pick"),
         {:ok, limit} <- optional_int(params, "limit"),
         opts <- [
           user_id: user_id,
           at_pick: at_pick,
           limit: limit,
           player_ids: to_id_list(params["player_ids"])
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

  # `String.to_integer/1` raises on anything non-numeric, and
  # `action_fallback` only catches `{:error, _}` *returns* — so parsing
  # these with it turned `?limit=abc` into a 500. A malformed query param
  # is the caller's mistake, not the server's.
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

  defp to_id_list(nil), do: nil

  defp to_id_list(value) when is_binary(value) do
    case value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      ids -> Enum.uniq(ids)
    end
  end
end
