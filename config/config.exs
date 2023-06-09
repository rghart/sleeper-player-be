# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sleeper_player_api,
  ecto_repos: [SleeperPlayerApi.Repo],
  generators: [binary_id: true]

# Configures the endpoint
config :sleeper_player_api, SleeperPlayerApiWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: SleeperPlayerApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SleeperPlayerApi.PubSub,
  live_view: [signing_salt: "D+bR61pb"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sleeper_player_api, SleeperPlayerApi.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Quantum cron jobs
config :sleeper_player_api, SleeperPlayerApi.Scheduler,
  jobs: [
    # Runs daily at 3am Central time:
    {"0 8 * * *", {SleeperPlayerApi.Tasks.GetSleeperPlayerData, :get_sleeper_player_data, []}}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
