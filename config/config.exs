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
  live_view: [signing_salt: "D+bR61pb"],
  # Compress responses. Cowboy's own stream handler does it, because there
  # is no reverse proxy in front of this app — it is `plug_cowboy` talking
  # to the internet directly (`Plug.Static`'s `gzip: false` was never
  # relevant: that only ever served pre-compressed *static* files, and
  # every response here is dynamic JSON).
  #
  # It has to be `compress: true`, NOT
  # `protocol_options: [stream_handlers: [:cowboy_compress_h, ...]]`.
  # `:stream_handlers` is a top-level `Plug.Cowboy` option, not a Cowboy
  # protocol option, and `Plug.Cowboy.args/4` merges its own default
  # handlers *over* anything nested under `:protocol_options`. The nested
  # form compiles, boots, and silently does nothing — verified by curling
  # a 4 KB response and finding no `content-encoding` on it.
  #
  # Set on both listeners, not just https, because the http one is what
  # answers before `force_ssl` redirects — and set here rather than in
  # `prod.exs` so dev and prod compress alike. Phoenix deep-merges these
  # keyword lists, so the per-environment `port`/`ip` entries survive, as
  # does `SiteEncrypt.Phoenix.configure_https/1`'s cert merge.
  #
  # The measured effect on the endpoint that motivated this: 40,861 bytes
  # to 4,511 for `/availability` at pick 1 with ten targets.
  http: [compress: true],
  https: [compress: true]

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

    # Hourly at :15 — refresh market values from KeepTradeCut.
    #
    # Hourly rather than nightly because KTC is continuously crowdsourced:
    # measured 2026-08-12, 7 of 500 values moved between two fetches roughly
    # two minutes apart. One 1.3MB page per run.
    #
    # At :15 so it never lands on the same minute as the nightly sweeps at
    # :00 and :30, which would have it contending with them four times a
    # night for nothing.
    #
    # The source is passed explicitly rather than read from
    # `:player_value_source`, which stays FantasyCalc — `Intel.Estimator` is
    # calibrated against that slice and this job must not re-base it.
    #
    # Note this writes a *daily close* to `player_value_history`, not 24 rows
    # a day: the hourly cadence is about catching a move promptly in the
    # current-value table, and the last write of a day wins in the series.
    [
      name: :refresh_ktc_values,
      schedule: "15 * * * *",
      task:
        {SleeperPlayerApi.Tasks.RefreshPlayerValues, :refresh_player_values,
         [SleeperPlayerApi.Intel.PlayerValueSources.KeepTradeCut]},
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
