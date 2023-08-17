import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.

config :sleeper_player_api, SleeperPlayerApiWeb.Endpoint,
       url: [host: "fantasyteamassistant.com", port: 443],
       cache_static_manifest: "priv/static/cache_manifest.json",
       server: true,
       force_ssl: [hsts: true],
       http: [port: 4000, transport_options: [socket_opts: [:inet6]]],
       https: [
         port: 4040,
         cipher_suite: :strong,
         transport_options: [socket_opts: [:inet6]]
       ]

# Set path to cert folder
config :sleeper_player_api, :cert_path, "/home/rhart/site_encrypt_db"

# Set the cert mode so site_encrypt knows to hit live LetsEncrypt
config :sleeper_player_api, :cert_mode, "production"

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: SleeperPlayerApi.Finch

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.

import_config "prod.secret.exs"
