import Config

# Set ports based on environment variables in the release
http_port = System.get_env("HTTP_PORT")
https_port = System.get_env("HTTPS_PORT")

if http_port && https_port do
  config :sleeper_player_api, SleeperPlayerApiWeb.Endpoint,
         http: [port: String.to_integer(http_port)],
         https: [port: String.to_integer(https_port)]
end
