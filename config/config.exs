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

# Sleeper API client rate limiter. Sleeper's documented ceiling is 1000
# calls/min; this is deliberately well under that — see the moduledoc on
# SleeperPlayerApi.RateLimiter for why.
config :sleeper_player_api, SleeperPlayerApi.RateLimiter, calls_per_minute: 300

# Leagues the leaguemate-intel crawler sweeps nightly (plan §3c). Not a
# secret — Sleeper league ids are public, and this one is already in the
# frontend's `src/urls.js`. One league today; making this per-user is the
# larger "configurable Sleeper user" change, not this one.
config :sleeper_player_api, :intel_leagues, [1_313_425_233_297_813_504]

# Season to crawl. Unset on purpose: the crawler falls back to the current
# calendar year, which is how Sleeper labels a season, so this rolls over
# without a deploy. Set it to pin a specific season.
# config :sleeper_player_api, :intel_season, "2026"

# Quantum cron jobs. Times are UTC; Central is UTC-5.
#
# Ordering matters: the player dump runs first because the intel crawler
# joins to `players` for name/position, and values land before the crawl so
# a fresh corpus is ranked against fresh market data. All three are well
# under a minute in practice (a warm crawl is ~22 API calls), but
# `overlap: false` means a pathological run can't stack on itself.
config :sleeper_player_api, SleeperPlayerApi.Scheduler,
  jobs: [
    # 3:00am Central — the nightly Sleeper player dump.
    {"0 8 * * *", {SleeperPlayerApi.Tasks.GetSleeperPlayerData, :get_sleeper_player_data, []}},

    # 3:30am Central — refresh market values from FantasyCalc.
    [
      name: :refresh_player_values,
      schedule: "30 8 * * *",
      task: {SleeperPlayerApi.Tasks.RefreshPlayerValues, :refresh_player_values, []},
      overlap: false
    ],

    # 4:00am Central — sweep leaguemate drafts. Completed drafts are
    # immutable and never refetched, so a warm run is cheap.
    [
      name: :crawl_leaguemate_drafts,
      schedule: "0 9 * * *",
      task: {SleeperPlayerApi.Tasks.CrawlLeaguemateDrafts, :crawl_configured_leagues, []},
      overlap: false
    ],

    # 4:30am Central — sweep leaguemate transactions. Last, because it is the
    # heaviest: measured against the live API at 365 calls cold and 189 warm,
    # against ~22 for a warm draft crawl. It runs after the draft sweep so the
    # two never contend for the same rate-limit bucket.
    #
    # A warm run stays at 189 rather than dropping further because the
    # offseason has no settled weeks: Sleeper files every offseason move under
    # week 1 and week 1 never closes, so the live week comes back every night.
    # That falls away once the season starts.
    [
      name: :crawl_leaguemate_transactions,
      schedule: "30 9 * * *",
      task: {SleeperPlayerApi.Tasks.CrawlLeaguemateTransactions, :crawl_configured_leagues, []},
      overlap: false
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
