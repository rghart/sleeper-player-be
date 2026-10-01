defmodule SleeperPlayerApi.Tasks.RefreshProjections do
  @moduledoc """
  Stores Sleeper's season-long projections for the power rankings'
  projection and ADP sources (docs/dynasty-engine.md, M1 step 3).

  The frontend used to fetch these itself, about 3MB per page load. Holding
  them here makes them one fetch a day for every caller, and lets the
  server rank a league without the browser.

  Runs nightly (see the Quantum jobs in `config/config.exs`) for the current
  league season, and on demand through `ensure/1` the first time a season is
  asked for, so a deploy does not have to wait for the job to be useful.

      SleeperPlayerApi.Tasks.RefreshProjections.refresh()
      SleeperPlayerApi.Tasks.RefreshProjections.refresh(2026)
  """

  require Logger

  alias SleeperPlayerApi.Client.{Sleeper, SleeperProjections}
  alias SleeperPlayerApi.Intel

  @doc """
  Fetches `season`'s projections and replaces the stored ones. Defaults to
  Sleeper's current `league_season`.

  Returns `{:ok, count}`, or `{:error, reason}` with nothing changed: a failed
  or empty fetch must not wipe a good earlier one, because the replace prunes
  every player the payload does not list.
  """
  @spec refresh(integer | nil) :: {:ok, non_neg_integer} | {:error, term}
  def refresh(season \\ nil) do
    season = season || current_season()

    case SleeperProjections.season(season) do
      {:ok, []} ->
        Logger.warning("RefreshProjections: #{season} came back empty; kept what was stored")
        {:error, :empty}

      {:ok, rows} ->
        count = Intel.replace_projections(season, rows)
        Logger.info("RefreshProjections: stored #{count} projections for #{season}")
        {:ok, count}

      {:error, reason} = error ->
        Logger.error("RefreshProjections: #{season} failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Makes sure `season` has stored projections, fetching them if none are.
  Returns whether it has them afterwards. False costs the rankings their
  projection and ADP sources and nothing else.
  """
  @spec ensure(integer) :: boolean
  def ensure(season) do
    Intel.projections_stored?(season) or match?({:ok, _}, refresh(season))
  end

  # Sleeper's own label for the season leagues are in, which rolls over
  # before the calendar does. The calendar year is the fallback when the
  # state endpoint is unreachable, which is right for most of the year.
  defp current_season do
    with {:ok, %{"league_season" => season}} <- Sleeper.get("/state/nfl"),
         {year, ""} <- Integer.parse(to_string(season)) do
      year
    else
      _ -> Date.utc_today().year
    end
  end
end
