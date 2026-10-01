defmodule SleeperPlayerApiWeb.UserSummaryController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Client.Sleeper
  alias SleeperPlayerApi.Intel.{LeagueSnapshot, UserSummary}

  action_fallback SleeperPlayerApiWeb.FallbackController

  # Snapshots load two at a time: each is five live Sleeper reads, and the
  # shared rate limiter paces them anyway. More in flight would only queue.
  @concurrency 2
  @league_timeout_ms 30_000

  @doc """
  `GET /api/v1/users/:user/summary` — a manager's position in every league
  they are in this season (`Intel.UserSummary`), by Sleeper username or user
  id (docs/dynasty-engine.md, M4).

  Only dynasty leagues (Sleeper type 2) are analysed. A redraft, keeper or
  guillotine league is listed with the reason it was skipped rather than
  given dynasty tiers it has no use for. A league that fails to load is
  listed with the error, and the rest still answer.
  """
  def show(conn, %{"user" => user}) do
    with {:ok, account} <- fetch_user(user),
         {:ok, season} <- fetch_season(),
         {:ok, leagues} <- fetch_leagues(account["user_id"], season) do
      entries =
        leagues
        |> Task.async_stream(&entry/1,
          max_concurrency: @concurrency,
          timeout: @league_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip(leagues)
        |> Enum.map(fn
          {{:ok, entry}, _league} -> entry
          {{:exit, _}, league} -> %{league: league, result: {:error, "timed out"}}
        end)

      render(conn, :show,
        account: account,
        season: season,
        summary: UserSummary.build(account["user_id"], entries)
      )
    end
  end

  defp entry(league) do
    %{league: league, result: load(league)}
  end

  defp load(%{"settings" => %{"type" => 2}} = league) do
    case LeagueSnapshot.load(league["league_id"]) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :no_dynasty_values} -> {:error, "no dynasty values are stored yet"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp load(league) do
    {:skipped, skip_reason(get_in(league, ["settings", "type"]))}
  end

  defp skip_reason(0), do: "redraft league: dynasty tiers, picks and sells do not apply"
  defp skip_reason(1), do: "keeper league: not analysed yet"
  defp skip_reason(3), do: "guillotine league: not analysed"
  defp skip_reason(type), do: "league type #{inspect(type)} is not dynasty"

  # Sleeper's /user/:x takes a username or a user id alike, and answers an
  # unknown one with 404 or a null body.
  defp fetch_user(user) do
    case Sleeper.get("/user/#{URI.encode(user)}") do
      {:ok, %{"user_id" => _} = account} -> {:ok, account}
      {:ok, _} -> {:error, :not_found}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # The season leagues are labelled with; the calendar year if Sleeper's
  # state cannot be read.
  defp fetch_season do
    case Sleeper.get("/state/nfl") do
      {:ok, %{"league_season" => season}} -> {:ok, to_string(season)}
      _ -> {:ok, Integer.to_string(Date.utc_today().year)}
    end
  end

  defp fetch_leagues(user_id, season) do
    case Sleeper.get("/user/#{user_id}/leagues/nfl/#{season}") do
      {:ok, leagues} when is_list(leagues) -> {:ok, leagues}
      {:ok, _} -> {:error, {:upstream_shape, "user leagues"}}
      {:error, _} = error -> error
    end
  end
end
