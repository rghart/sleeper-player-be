defmodule SleeperPlayerApiWeb.TradeJSON do
  @moduledoc """
  Renders `Intel.TradeFinder.find/3` — camelCase keys, same split as the
  other JSON modules here.

  Player ids only, never names: every caller already holds the whole player
  database (the frontend downloads it for the draft board), so returning
  names would ship a second copy of data the caller is holding to save it a
  map lookup. Same reasoning as `PlayerValueJSON`.
  """

  @doc """
  The suggestions, plus the roster shape they were matched on.

  `depth` and `starters` travel with them deliberately. A suggestion says
  "you are deep here and thin there", and a caller that cannot show the
  counts behind that is asking to be trusted rather than showing its working
  — which is the failure mode this whole feature set keeps re-learning.

  Both `rawGap` and `adjustedGap` are sent for the same reason: the
  interesting thing about a package trade is usually how far the two differ.
  """
  def index(%{
        source: source,
        league_id: league_id,
        window_aware: window_aware,
        tep: tep,
        suggestions: suggestions,
        depth: depth,
        starters: starters,
        league_average: league_average
      }) do
    %{
      source: source,
      leagueId: to_string(league_id),
      rosterShape: %{
        depth: depth,
        starters: starters,
        # What `depth` is measured against. `starters` is here for display —
        # "you start 2" — but it is `leagueAverage` that decides deep or thin,
        # and showing one without the other points at the wrong yardstick.
        leagueAverage: league_average
      },
      # Whether suggestions are ordered by what each side gains in its
      # window, or (when the league could not be ranked) by fit alone.
      windowAware: window_aware,
      # KTC's TE-premium tier the values used, or null for none.
      tep: tep,
      suggestions: Enum.map(suggestions, &suggestion/1)
    }
  end

  defp suggestion(s) do
    %{
      partnerId: s.partner_id,
      partnerName: s.partner_name,
      give: s.give,
      get: s.get,
      # Separate arrays rather than mixed into `give`/`get`: those hold
      # Sleeper player ids and a pick is not a player, the same split that
      # keeps `draft_pick_values` out of `player_values`.
      givePicks: Enum.map(s.give_picks || [], &pick/1),
      getPicks: Enum.map(s.get_picks || [], &pick/1),
      giveValue: round_to(s.give_value),
      getValue: round_to(s.get_value),
      rawGap: round_to(s.raw_gap),
      adjustedGap: round_to(s.adjusted_gap),
      myFit: s.my_fit,
      theirFit: s.their_fit,
      # What the trade is worth to each side in its window, as a share of the
      # league average: a contender's lineup now, a rebuilder's future, the
      # mean of both for a team in the middle. `mutualGain` is the smaller,
      # which is what the list is ordered by.
      myWindow: window(s[:my_window]),
      theirWindow: window(s[:their_window]),
      mutualGain: s[:mutual_gain]
    }
  end

  defp window(nil), do: nil
  defp window(w), do: %{tier: w.tier, gain: w.gain, now: w.now, future: w.future}

  # `tier` travels even though it is always "mid" today: the caller is
  # rendering "2027 2nd" and the tier is the part of that claim it did not
  # get to choose.
  defp pick(%{season: season, round: round}) do
    %{season: season, round: round, tier: "mid"}
  end

  # Whole numbers on the wire. These are adjusted values on a 0-10,000 scale
  # where the sixth decimal is noise, and a UI rendering "1179.0731754" would
  # be claiming a precision the model does not have.
  defp round_to(nil), do: nil
  defp round_to(n) when is_float(n), do: Float.round(n, 1)
  defp round_to(n), do: n
end
