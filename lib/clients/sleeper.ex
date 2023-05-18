defmodule SleeperPlayerApi.Client.Sleeper do
  use HTTPoison.Base

  @sleeper_url "https://api.sleeper.app/v1"

  def process_request_url(url) do
    @sleeper_url <> url
  end

  def process_response_body(body) do
    body
    |> Jason.decode!
  end
end
