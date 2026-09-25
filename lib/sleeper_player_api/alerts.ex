defmodule SleeperPlayerApi.Alerts do
  @moduledoc """
  Push notifications to Ryan's phone, through ntfy (https://ntfy.sh).

  ntfy is a plain HTTP POST to a topic URL: the body is the message, the
  title and priority ride in headers, and whoever is subscribed to the topic
  in the ntfy app gets the push. No account and no key - the topic name is
  the secret, which is why the URL lives in `config/prod.secret.exs` on the
  server and never in this (public) repository.

  Unconfigured, `push/3` logs and returns `{:error, :not_configured}` rather
  than raising: dev and test must be able to run every job that alerts
  without sending anything anywhere, and a missing alert channel is not a
  reason to fail the job that noticed the problem.
  """

  require Logger

  @doc """
  Sends one push. `opts`: `:priority` (`"default"`, `"high"`, ...) and
  `:tags` (ntfy emoji shortcodes, e.g. `["warning"]`).
  """
  @spec push(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def push(title, message, opts \\ []) do
    case Application.get_env(:sleeper_player_api, :alert_push_url) do
      url when is_binary(url) and url != "" ->
        headers =
          [
            {"Title", title},
            {"Priority", Keyword.get(opts, :priority, "default")}
          ] ++ tag_header(Keyword.get(opts, :tags, []))

        case HTTPoison.post(url, message, headers, recv_timeout: 10_000) do
          {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 ->
            :ok

          {:ok, %HTTPoison.Response{status_code: status}} ->
            Logger.error("Alerts: push #{inspect(title)} failed with HTTP #{status}")
            {:error, {:http_error, status}}

          {:error, %HTTPoison.Error{reason: reason}} ->
            Logger.error("Alerts: push #{inspect(title)} failed: #{inspect(reason)}")
            {:error, {:transport_error, reason}}
        end

      _ ->
        Logger.warning("Alerts: no :alert_push_url configured; not sending #{inspect(title)}")
        {:error, :not_configured}
    end
  end

  defp tag_header([]), do: []
  defp tag_header(tags), do: [{"Tags", Enum.join(tags, ",")}]
end
