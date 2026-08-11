defmodule SleeperPlayerApi.Intel.MarketValues do
  @moduledoc """
  Reading market values for a given league shape.

  Two ways to answer, and the caller does not choose between them. The stored
  slice — the one `RefreshPlayerValues` writes nightly — comes out of the
  database. Anything else is fetched from the provider and cached, because
  storing every combination of format, league size and scoring would be a
  nightly job against a space nobody has enumerated, for slices most of which
  no one will ever ask about.

  The cache is a courtesy to FantasyCalc more than a speed measure. They are
  a free, unauthenticated, public API and this app is a guest: a rank list is
  a button press, and a button press should not become a third-party request
  every time somebody presses it twice.
  """

  alias SleeperPlayerApi.Intel
  alias SleeperPlayerApi.Intel.MarketSettings
  alias SleeperPlayerApi.Intel.MarketValuesCache

  @source "fantasycalc"

  @doc """
  The values for `settings`, best player first.

  Returns `{:error, reason}` only for a live fetch that failed. The stored
  slice cannot fail this way — an empty table is `{:ok, []}`, which is a
  truthful "the refresh has not run yet" rather than an error.
  """
  @spec values(MarketSettings.t()) :: {:ok, [map]} | {:error, term}
  def values(settings) do
    if MarketSettings.default?(settings) do
      {:ok, Intel.player_values(@source)}
    else
      fetch(settings)
    end
  end

  defp fetch(settings) do
    key = MarketSettings.to_query(settings)

    case MarketValuesCache.get(key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case source().fetch_values(settings) do
          {:ok, entries} ->
            values = entries |> Enum.map(&shape/1) |> Enum.sort_by(&sort_key/1)
            MarketValuesCache.put(key, values)
            {:ok, values}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # The provider shapes for the database — source, roster_percent,
  # trade_frequency, draft_year — and none of that reaches a caller asking for
  # a ranking list. Narrowed here so the live path and the stored path hand
  # back the same thing and the JSON view cannot tell them apart.
  defp shape(entry) do
    %{
      player_id: entry.player_id,
      value: entry.value,
      overall_rank: entry.overall_rank,
      position_rank: entry.position_rank,
      as_of: entry.as_of
    }
  end

  # Same order the stored query uses, nulls last: a player the feed has no
  # opinion on must not open the list.
  defp sort_key(%{overall_rank: nil}), do: {1, 0}
  defp sort_key(%{overall_rank: rank}), do: {0, rank}

  defp source do
    Application.get_env(
      :sleeper_player_api,
      :player_value_source,
      SleeperPlayerApi.Intel.PlayerValueSources.FantasyCalc
    )
  end
end
