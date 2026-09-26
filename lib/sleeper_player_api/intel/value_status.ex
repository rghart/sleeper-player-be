defmodule SleeperPlayerApi.Intel.ValueStatus do
  @moduledoc """
  Whether the market values are current, for the app to warn about.

  Exists because KeepTradeCut moved its page data on 2026-09-08 and the
  hourly refresh failed for 16 days before anyone noticed: every run logged
  `:players_array_not_found`, and nothing reads the logs. This reads the one
  thing that matters instead - how old the newest stored value is - so it
  catches any cause: a changed page, a dead scheduler, a job that "succeeds"
  while writing nothing. The app shows a banner whenever it reports a problem.

  (A push notification did this job for a day; Ryan preferred the banner.)
  """

  import Ecto.Query

  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Repo

  # Each check covers the sources one job writes. KTC's two variants come
  # from one fetch, so they fail together and are reported as one.
  @checks [
    # Refreshed hourly at :15; three missed runs is a broken job, not a slow one.
    %{name: "KeepTradeCut", sources: ["keeptradecut:sf", "keeptradecut:1qb"], max_age_hours: 3},
    # Refreshed nightly at 08:30 UTC; a missed night plus slack.
    %{name: "FantasyCalc", sources: ["fantasycalc"], max_age_hours: 30}
  ]

  @unrecognized_key {__MODULE__, :unrecognized_picks}

  @doc """
  One entry per source - `%{name, as_of, max_age_hours, stale}` - plus the
  KTC picks the last refresh could not read.
  """
  @spec status(DateTime.t()) :: %{sources: [map], unrecognized_picks: map}
  def status(now \\ DateTime.utc_now()) do
    %{
      sources:
        Enum.map(@checks, fn check ->
          as_of = oldest_newest(check.sources)

          %{
            name: check.name,
            as_of: as_of,
            max_age_hours: check.max_age_hours,
            stale: as_of == nil or DateTime.diff(now, as_of, :second) > check.max_age_hours * 3600
          }
        end),
      unrecognized_picks: :persistent_term.get(@unrecognized_key, %{count: 0, examples: []})
    }
  end

  @doc """
  Records the picks KTC listed that the refresh could not read, replacing
  whatever the previous refresh recorded - so a naming fix clears it on the
  next run. Held in `:persistent_term`: a deploy forgets it, and the next
  hourly refresh sets it again.
  """
  @spec record_unrecognized_picks([map]) :: :ok
  def record_unrecognized_picks(picks) do
    :persistent_term.put(@unrecognized_key, %{
      count: length(picks),
      examples: picks |> Enum.take(3) |> Enum.map(& &1["playerName"])
    })
  end

  @doc false
  def reset, do: :persistent_term.erase(@unrecognized_key)

  # The OLDEST of the sources' newest values: if one of KTC's two variants
  # stopped updating, the status must see that one, not the healthy one.
  # nil when any source has nothing stored at all.
  defp oldest_newest(sources) do
    newest =
      from(pv in PlayerValue,
        where: pv.source in ^sources,
        group_by: pv.source,
        select: {pv.source, max(pv.as_of)}
      )
      |> Repo.all()
      |> Map.new()

    if Enum.all?(sources, &Map.has_key?(newest, &1)) do
      newest |> Map.values() |> Enum.min(DateTime)
    end
  end
end
