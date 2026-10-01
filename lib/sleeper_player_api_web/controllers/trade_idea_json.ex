defmodule SleeperPlayerApiWeb.TradeIdeaJSON do
  @moduledoc "Renders `Intel.TradeSearch` ideas, camelCase like the rest of this API."

  alias SleeperPlayerApi.Intel.TradeFairness

  def show(assigns) do
    %{
      leagueId: assigns.league_id,
      mode: assigns.mode,
      # KTC's TE-premium tier the market values used, or null.
      tep: assigns.tep,
      # What "now" was measured on: "proj" (projected points) or "ktc".
      nowSource: to_string(assigns.now_source),
      ideas: Enum.map(assigns.ideas, &idea/1)
    }
  end

  defp idea(i) do
    %{
      partnerId: i.partner_id,
      partnerName: i.partner_name,
      give: i.give,
      get: i.get,
      givePicks: Enum.map(i.give_picks, &pick/1),
      getPicks: Enum.map(i.get_picks, &pick/1),
      # Which pieces were added to even it, and by whom ("give": you added,
      # "get": they added). Null when it was even as proposed.
      added: added(i.added),
      # Market value, after KTC's package adjustment: what makes it even.
      market: %{
        give: i.give_value,
        get: i.get_value,
        gapPct: (i.get_value - i.give_value) / max(max(i.give_value, i.get_value), 1),
        # The share of real accepted trades less even than this one: 0.8 is
        # "more even than 80% of trades managers actually made".
        moreEvenThan: TradeFairness.more_even_than(TradeFairness.gap(i.give_value, i.get_value))
      },
      # Season projections: what each lineup gains this season, in points.
      season: %{mine: i.my_window.now_points, theirs: i.their_window.now_points},
      myWindow: window(i.my_window),
      theirWindow: window(i.their_window),
      score: i.score
    }
  end

  defp added(nil), do: nil

  defp added(a),
    do: %{side: to_string(a.side), players: a.players, picks: Enum.map(a.picks, &pick/1)}

  defp pick(p), do: %{season: p.season, round: p.round, tier: p[:tier], value: p[:value]}

  defp window(w), do: %{tier: w.tier, gain: w.gain, now: w.now, future: w.future}
end
