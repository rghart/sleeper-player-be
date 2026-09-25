defmodule SleeperPlayerApi.Tasks.CheckValueFreshness do
  @moduledoc """
  Pushes an alert when a market-value source stops refreshing.

  Exists because KeepTradeCut moved its page data on 2026-09-08 and the
  hourly refresh failed for 16 days before anyone noticed. Every one of those
  runs logged `:players_array_not_found`; nothing reads the logs. This reads
  the one thing that matters instead - how old the newest stored value is -
  so it catches any cause: a changed page, a crashed scheduler, a job that
  "succeeds" while writing nothing.

  Runs hourly. It pushes once when a source goes stale, again every
  `@remind_after_hours` while it stays stale, and once more when it recovers,
  so a broken source is a handful of notifications rather than one an hour.
  What has been alerted is held in `:persistent_term`, which a deploy
  clears: the worst case is one repeat alert after a deploy, which is a
  better failure than a table to migrate for this.
  """

  require Logger
  import Ecto.Query

  alias SleeperPlayerApi.Alerts
  alias SleeperPlayerApi.Intel.PlayerValue
  alias SleeperPlayerApi.Repo

  # Each check covers the sources one job writes. KTC's two variants come
  # from one fetch, so they fail together and alert as one.
  @checks [
    # Refreshed hourly at :15; three missed runs is a broken job, not a slow one.
    %{name: "KeepTradeCut", sources: ["keeptradecut:sf", "keeptradecut:1qb"], max_age_hours: 3},
    # Refreshed nightly at 08:30 UTC; a missed night plus slack.
    %{name: "FantasyCalc", sources: ["fantasycalc"], max_age_hours: 30}
  ]

  @remind_after_hours 24

  @doc """
  Checks every source against `now` and pushes whatever is due. Returns one
  `{name, status}` per check - `:fresh`, `:stale`, `:recovered` - for tests
  and for anyone running it by hand.
  """
  @spec check(DateTime.t()) :: [{String.t(), atom}]
  def check(now \\ DateTime.utc_now()) do
    Enum.map(@checks, fn check -> {check.name, check_one(check, now)} end)
  end

  @doc "Forgets every alert sent, for tests."
  def reset do
    Enum.each(@checks, fn check -> :persistent_term.erase(key(check.name)) end)
  end

  defp check_one(check, now) do
    newest = newest_as_of(check.sources)
    alerted_at = :persistent_term.get(key(check.name), nil)

    if stale?(newest, check.max_age_hours, now) do
      if alerted_at == nil or DateTime.diff(now, alerted_at, :hour) >= @remind_after_hours do
        Alerts.push(
          "#{check.name} values are stale",
          stale_message(check, newest, now),
          priority: "high",
          tags: ["warning"]
        )

        :persistent_term.put(key(check.name), now)
      end

      :stale
    else
      if alerted_at != nil do
        Alerts.push(
          "#{check.name} values are refreshing again",
          "Newest value is from #{format(newest)}.",
          tags: ["white_check_mark"]
        )

        :persistent_term.erase(key(check.name))
        :recovered
      else
        :fresh
      end
    end
  end

  # The OLDEST of the sources' newest values: if one of KTC's two variants
  # stopped updating, the check must see that one, not the healthy one.
  defp newest_as_of(sources) do
    newest_by_source =
      from(pv in PlayerValue,
        where: pv.source in ^sources,
        group_by: pv.source,
        select: {pv.source, max(pv.as_of)}
      )
      |> Repo.all()
      |> Map.new()

    if Enum.all?(sources, &Map.has_key?(newest_by_source, &1)) do
      newest_by_source |> Map.values() |> Enum.min(DateTime)
    end
  end

  defp stale?(nil, _max_age_hours, _now), do: true

  defp stale?(newest, max_age_hours, now),
    do: DateTime.diff(now, newest, :second) > max_age_hours * 3600

  defp stale_message(check, nil, _now),
    do: "No #{check.name} values are stored at all. Check the refresh job's logs."

  defp stale_message(check, newest, now) do
    hours = div(DateTime.diff(now, newest, :second), 3600)

    "Newest #{check.name} value is from #{format(newest)}, #{hours}h ago " <>
      "(limit #{check.max_age_hours}h). The refresh job is failing or not running; check its logs."
  end

  defp format(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp key(name), do: {__MODULE__, name}
end
