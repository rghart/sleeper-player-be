defmodule SleeperPlayerApiWeb.TradeIdeaController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.Intel.{LeagueSnapshot, TradeSearch, TradeWindow}

  action_fallback SleeperPlayerApiWeb.FallbackController

  @doc """
  `GET /api/v1/leagues/:league_id/trade-ideas?user_id=&mode=` — trade ideas
  for one manager (`Intel.TradeSearch`), every one even on market value.

  `mode` picks what is suggested: `window` (default; both sides gain in their
  own window), `win_now` (your projected lineup improves, theirs does not lose
  in its window) or `market` (you come out ahead on market value, they do not
  lose in their window).

  Built on the league's `LeagueSnapshot`, so it shares `/rankings`' Sleeper
  reads, values and pick prices. The older `/trades` finder stays for the app
  until it moves over.
  """
  def show(conn, %{"league_id" => league_id} = params) do
    with {:ok, user_id} <- require_user(params["user_id"]),
         {:ok, mode} <- parse_mode(params["mode"]),
         {:ok, snapshot} <- LeagueSnapshot.load(league_id) do
      window = TradeWindow.context(snapshot, %{})
      context = TradeSearch.context(snapshot, window)

      case TradeSearch.ideas(context, user_id, mode) do
        {:ok, ideas} ->
          render(conn, :show,
            league_id: league_id,
            mode: mode,
            tep: snapshot.ktc_tep,
            now_source: window.now_source,
            ideas: ideas
          )

        {:error, :not_in_league} ->
          {:error, {:not_in_league, user_id}}
      end
    end
  end

  defp require_user(nil), do: {:error, {:missing_param, :user_id}}
  defp require_user(""), do: {:error, {:missing_param, :user_id}}
  defp require_user(user_id), do: {:ok, to_string(user_id)}

  defp parse_mode(nil), do: {:ok, "window"}

  defp parse_mode(mode) when is_binary(mode) do
    if mode in TradeSearch.modes(), do: {:ok, mode}, else: {:error, {:invalid_param, :mode, mode}}
  end
end
