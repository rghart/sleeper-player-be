defmodule SleeperPlayerApi.Market.Format do
  @moduledoc """
  Which drafts count toward market ADP, and which format each belongs to
  (docs/dynasty-engine.md, M3). Pure: reads Sleeper's draft and league
  objects, decides.

  **A format bucket is `{kind, qb, tep}`**: rookie or startup, 1QB or
  superflex, TE premium or not. Those are what change the order players go
  in. Quarterbacks go rounds earlier when a lineup can start two, and tight
  ends earlier when catches pay more. Team count and PPR are recorded on the
  draft but are not buckets: pick numbers barely move with league size, and
  nearly every dynasty league is full PPR, so splitting on either would thin
  every sample for little gain.

  The rules, all tunable in config:

    * `complete` drafts only: an in-progress or abandoned draft says nothing
      settled about where players go.
    * **dynasty** drafts only: Sleeper's `scoring_type` starts `dynasty`.
    * **rookie** is `player_type` 1, as the leaguemate crawler reads it.
      **startup** is `player_type` 0 with at least `startup_min_rounds`
      rounds, which is what tells a startup from a short supplemental draft.
    * at least `min_teams` teams: tiny test leagues draft nothing like real
      ones.
    * started within the last `window_days`, so ADP tracks the market now.
  """

  @rookie_player_type 1
  @all_players_type 0

  defp config(key, default) do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc "The fewest rounds a player_type 0 dynasty draft needs to count as a startup."
  def startup_min_rounds, do: config(:startup_min_rounds, 15)

  @doc "The fewest teams a draft needs to count."
  def min_teams, do: config(:min_teams, 8)

  @doc "How far back a draft may have started and still count, in days."
  def window_days, do: config(:window_days, 365)

  @doc "The earliest start time that still counts, as a DateTime."
  def window_start(now \\ DateTime.utc_now()),
    do: DateTime.add(now, -window_days() * 86_400, :second)

  @doc """
  Whether a draft object (from `/user/:id/drafts`) qualifies, as
  `{:ok, kind}` or `{:skip, reason}`. The reason is an atom the crawler counts,
  so a run reports how much each rule drops.
  """
  def classify(draft, now \\ DateTime.utc_now()) do
    settings = draft["settings"] || %{}
    scoring = get_in(draft, ["metadata", "scoring_type"]) || ""

    cond do
      draft["status"] != "complete" -> {:skip, :not_complete}
      not String.starts_with?(scoring, "dynasty") -> {:skip, :not_dynasty}
      (settings["teams"] || 0) < min_teams() -> {:skip, :too_few_teams}
      not within_window?(draft["start_time"], now) -> {:skip, :outside_window}
      kind = kind(settings) -> {:ok, kind}
      true -> {:skip, :not_rookie_or_startup}
    end
  end

  defp kind(%{"player_type" => @rookie_player_type}), do: "rookie"

  defp kind(%{"player_type" => @all_players_type} = settings) do
    if (settings["rounds"] || 0) >= startup_min_rounds(), do: "startup"
  end

  defp kind(_settings), do: nil

  defp within_window?(ms, now) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, started} -> DateTime.compare(started, window_start(now)) != :lt
      _ -> false
    end
  end

  defp within_window?(_ms, _now), do: false

  @doc """
  How many quarterbacks a lineup can start, from a draft's slot settings:
  QB slots plus superflex. Two or more is superflex drafting.
  """
  def qb_slots(draft) do
    settings = draft["settings"] || %{}
    (settings["slots_qb"] || 0) + (settings["slots_super_flex"] || 0)
  end

  @doc "The format bucket for a kind, a QB-slot count and a TE premium."
  def bucket(kind, qb_slots, te_premium) do
    {kind, if((qb_slots || 0) >= 2, do: "sf", else: "1qb"),
     if((te_premium || 0) > 0, do: "tep", else: "no_tep")}
  end

  @doc "Every bucket, in a stable order."
  def buckets do
    for kind <- ["startup", "rookie"],
        qb <- ["sf", "1qb"],
        tep <- ["no_tep", "tep"],
        do: {kind, qb, tep}
  end

  @doc "A bucket as the string an API caller names it by, `startup-sf-tep`."
  def bucket_key({kind, qb, tep}), do: "#{kind}-#{qb}-#{tep}"

  @doc "The bucket a key names, or `:error` for one that is not a bucket."
  def parse_key(key) do
    case Enum.find(buckets(), &(bucket_key(&1) == key)) do
      nil -> :error
      bucket -> {:ok, bucket}
    end
  end

  @doc """
  Sleeper's ADP column to compare a bucket against, and what it is.

  Sleeper publishes dynasty startup ADP in two variants, superflex
  (`adp_dynasty_2qb`) and PPR (`adp_dynasty_ppr`), and nothing for TE
  premium. Its `adp_rookie` column was empty for every player when this was
  written (checked 2026-10-01), so a rookie bucket is compared against the
  startup column ranked among the same rookies: the comparison is of order
  among shared players, so that still asks whether Sleeper orders the class
  the way real rookie drafts do.
  """
  def sleeper_column({kind, qb, tep}) do
    column = if qb == "sf", do: "adp_dynasty_2qb", else: "adp_dynasty_ppr"

    notes =
      [
        kind == "rookie" &&
          "Sleeper's rookie ADP is empty, so this is its startup ADP ranked among these rookies.",
        tep == "tep" &&
          "Sleeper has no TE-premium ADP; this compares against its non-premium column."
      ]
      |> Enum.filter(& &1)

    %{column: column, notes: notes}
  end
end
