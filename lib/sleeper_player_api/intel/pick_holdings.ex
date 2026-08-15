defmodule SleeperPlayerApi.Intel.PickHoldings do
  @moduledoc """
  Which rookie picks each roster in a league actually still holds.

  Two things have to be true for a pick to be tradeable, and Sleeper only
  answers one of them directly.

  **Who owns it.** Every roster starts owning its own pick in every round of
  every future draft; `GET /league/:id/traded_picks` lists only the ones that
  have changed hands. So ownership is the default set with those overrides
  applied — the endpoint alone would report a league where nobody owns
  anything.

  **Whether it still exists.** This is the part that bites. KeepTradeCut goes
  on pricing "2026 Early 1st" after the 2026 rookie drafts are done, because
  its list is about a market, not about your league. District 13's 2026 draft
  is `complete` and the league is `in_season`, so a 2026 pick there is spent —
  and a trade offering one would have looked completely plausible. Seasons
  are therefore taken from **the league's own drafts**, never from the price
  list: any season with a completed draft is excluded.

  That is also why this does not simply filter on `season >= current`. The
  current season's draft may or may not have happened, and only the league
  knows which.
  """

  @doc """
  `%{roster_id => [%{season: 2027, round: 1}, ...]}` for every roster.

  `drafts` is the league's `GET /league/:id/drafts` payload, `traded` its
  `GET /league/:id/traded_picks`, and `priced_seasons` the seasons the value
  source can actually put a number on — a pick nobody prices is not worth
  offering, since the whole point is closing a value gap.
  """
  @spec build([map], [map], [integer], keyword) :: %{integer => [map]}
  def build(drafts, traded, priced_seasons, opts \\ []) do
    rounds = Keyword.get(opts, :rounds, 4)
    roster_ids = Keyword.get(opts, :roster_ids, [])

    seasons = tradeable_seasons(drafts, priced_seasons)
    overrides = Map.new(traded, fn t -> {key(t), t["owner_id"]} end)

    for roster_id <- roster_ids,
        season <- seasons,
        round <- 1..rounds,
        # The pick originally belonging to `roster_id`, unless it was traded.
        owner = Map.get(overrides, {season, round, roster_id}, roster_id),
        reduce: %{} do
      acc ->
        Map.update(
          acc,
          owner,
          [%{season: season, round: round}],
          &[%{season: season, round: round} | &1]
        )
    end
  end

  @doc """
  Seasons whose rookie draft has not happened yet *in this league*, narrowed
  to the ones a value source prices.

  Public because it is the rule most likely to be wanted elsewhere, and the
  one it would be easiest to get wrong somewhere else.
  """
  @spec tradeable_seasons([map], [integer]) :: [integer]
  def tradeable_seasons(drafts, priced_seasons) do
    completed =
      drafts
      |> Enum.filter(&(&1["status"] == "complete"))
      |> MapSet.new(&to_season(&1["season"]))

    priced_seasons
    |> Enum.reject(&MapSet.member?(completed, &1))
    |> Enum.sort()
  end

  defp key(traded), do: {to_season(traded["season"]), traded["round"], traded["roster_id"]}

  # Sleeper sends a season as a string on some payloads and an integer on
  # others; a map keyed by one and read with the other silently matches
  # nothing, which here would read as "no picks were ever traded".
  defp to_season(season) when is_integer(season), do: season

  defp to_season(season) when is_binary(season) do
    case Integer.parse(season) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp to_season(_), do: nil
end
