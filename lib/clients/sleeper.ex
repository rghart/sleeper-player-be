defmodule SleeperPlayerApi.Client.Sleeper do
  use HTTPoison.Base

  def process_request_url(url) do
    "https://api.sleeper.app/v1" <> url
  end

  def process_response_body(body) do
    body
    |> Jason.decode()
  end
end