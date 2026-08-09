defmodule SleeperPlayerApiWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use SleeperPlayerApiWeb, :controller

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SleeperPlayerApiWeb.ErrorHTML, json: SleeperPlayerApiWeb.ErrorJSON)
    |> render(:"404")
  end

  # `AvailabilityController` (plan §3f step 4): the draft id in the URL
  # isn't in Sleeper at all (never crawled, and `/draft/:id` itself 404s).
  def call(conn, {:error, :draft_not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SleeperPlayerApiWeb.ErrorHTML, json: SleeperPlayerApiWeb.ErrorJSON)
    |> render(:"404")
  end

  # A required query param is missing (`AvailabilityController` requires
  # `user_id`).
  def call(conn, {:error, {:missing_param, key}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{errors: %{detail: "missing required param: #{key}"}})
  end

  # A query param that must be numeric wasn't (`AvailabilityController`'s
  # `at_pick`/`limit`). Previously these were parsed with
  # `String.to_integer/1`, which raises rather than returning an error, so
  # `?limit=abc` came back as a 500.
  def call(conn, {:error, {:invalid_param, key, value}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{
      errors: %{detail: "#{key} must be an integer, got: #{inspect(value)}"}
    })
  end

  # `at_pick` parsed as an integer but isn't a pick this draft has
  # (`SleeperPlayerApi.Intel.Availability.build/1`). The upper bound is
  # `last_pick + 1` because that is the `currentPick` a finished draft
  # reports — see the range check itself for why.
  def call(conn, {:error, {:pick_out_of_range, at_pick, last_pick}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{
      errors: %{
        detail:
          "at_pick must be between 1 and #{last_pick + 1} for this #{last_pick}-pick draft, got: #{at_pick}"
      }
    })
  end

  # `SleeperPlayerApi.Intel.PickOwnership` couldn't resolve the draft's own
  # order (not `"linear"`/`"snake"`) — per `Availability`'s moduledoc, this
  # is a hard failure rather than a degraded response, because serving
  # survival numbers computed from unresolved pick ownership is the one
  # thing the plan says this feature must never do.
  def call(conn, {:error, {:unsupported_draft_type, type}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{errors: %{detail: "unsupported draft type: #{type}"}})
  end

  # `PickOwnership.resolve_roster/5` couldn't find a roster for a draft
  # slot — Sleeper's `slot_to_roster_id` was missing or incomplete for this
  # draft. Same "hard failure, never a fabricated board" reasoning as
  # `:unsupported_draft_type` above.
  def call(conn, {:error, {:unmapped_slot, slot}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{errors: %{detail: "no roster mapped for draft slot #{slot}"}})
  end

  # Anything else an action returns as `{:error, reason}` — e.g. the
  # `/league/:id/rosters` fetch in `Intel.availability/2` failing.
  def call(conn, {:error, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> put_view(json: SleeperPlayerApiWeb.ErrorJSON)
    |> Phoenix.Controller.json(%{errors: %{detail: inspect(reason)}})
  end
end
