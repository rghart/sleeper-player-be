defmodule SleeperPlayerApi.Intel.PlayerValueSource do
  @moduledoc """
  The swappable player-value provider interface plan §2 calls for:

  > "Build the value layer behind a `PlayerValueSource` interface so the
  > source is one swappable module. Then this is a config change, not a
  > rewrite, and you can decide about KTC later without it touching the
  > model."

  One behaviour, one implementation
  (`SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalc`) — this is
  deliberately not over-built (no registry, no multi-source merge). The
  seam that matters is that `SleeperPlayerApi.Tasks.RefreshPlayerValues`
  depends on this behaviour, not on `SleeperPlayerApi.Client.FantasyCalc`
  directly, and the module it uses is one line of config
  (`config :sleeper_player_api, :player_value_source, ...`) away from being
  swapped for a KTC/DynastyProcess implementation later.
  """

  @typedoc """
  One player's value, shaped exactly as `SleeperPlayerApi.Intel.upsert_player_values/1`
  expects — `source` is this provider's own name (the `player_values.source`
  discriminator column, plan §3a), and `draft_year` is the rookie-class
  filter input (plan §3f step 5 / estimator §8), `nil` when the provider has
  no draft-year data for that player at all.
  """
  @type value_entry :: %{
          player_id: integer,
          source: String.t(),
          value: float | nil,
          overall_rank: integer | nil,
          position_rank: integer | nil,
          roster_percent: float | nil,
          trade_frequency: float | nil,
          as_of: DateTime.t(),
          draft_year: integer | nil
        }

  @doc "This provider's `player_values.source` value."
  @callback name() :: String.t()

  @doc """
  Fetches every value this provider currently has. `{:error, reason}` on
  any fetch/decode failure — callers (`RefreshPlayerValues`) do not partially
  upsert a failed fetch.
  """
  @callback fetch_values() :: {:ok, [value_entry]} | {:error, term}
end
