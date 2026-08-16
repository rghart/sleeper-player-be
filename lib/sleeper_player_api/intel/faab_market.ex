defmodule SleeperPlayerApi.Intel.FaabMarket do
  @moduledoc """
  What players actually cost in FAAB across the observed leagues — not a
  projection, what was *paid*.

  Reads `observed_transactions`, which the nightly crawl has been filling
  since 2026-08-08 and which nothing outside a single manager's profile has
  ever looked at in aggregate. No new request, no new table.

  ## Every figure here is a share of the league's own budget

  Measured 2026-08-15 across the 147 FAAB leagues in the corpus: budget 100 on
  67 of them, 1000 on 33, 200 on 19, 300 on 14, 150 on 7, 250 on 4, 500 on 2,
  400 on 1. Fewer than half use the standard hundred, so a raw bid of 50 is
  half a budget in one league and a twentieth in another. Every bid is divided
  by `observed_leagues.waiver_budget` before it meets another bid.

  Leagues on rolling waivers or priority (`waiver_type` 0 and 1, 31 of them)
  are excluded outright rather than contributing zeros. Sleeper stores
  `waiver_bid` on every transaction regardless of waiver system, so those
  zeros are not bids of nothing — they are the absence of bidding, and pooling
  them would drag every figure toward zero while looking like data.

  ## A distribution, never a price

  The same player goes for wildly different money in different leagues:
  measured over the corpus, players with five or more winning claims routinely
  span 0% to 100% of budget. So this returns `median`, `low` and `high`
  together and no caller can render one without them. A single "he costs 12%"
  would be a fiction about a spread that wide — the same discipline the
  survival number follows, where the distribution *is* the answer.

  ## What counts as a price

  Only **winning** claims (`status: "complete"`). A failed claim is a bid that
  did not buy the player, and averaging it into what he cost would report a
  price nobody paid. Failed claims are returned separately, as a count, and
  deliberately without interpretation: Sleeper does not say *why* a claim
  failed, and "outbid" and "invalid roster move" look identical here.

  Every winning claim in the corpus adds exactly one player (3,404 of 3,404
  measured), so a bid attributes to a player unambiguously. If a multi-player
  claim ever appears, the bid bought the whole claim and this would start
  overstating each piece — worth re-checking if `adds` sizes ever change.

  ## The window is not optional

  The corpus runs from 2025-12-31 to the present, and it is **all offseason**
  with respect to the 2026 season, which has not started. Measured 2026-08-15,
  winning claims by month: Dec 2, Jan 167, Feb 26, Mar 150, Apr 227, May 1327,
  Jun 602, Jul 379, Aug 524. May dominates because that is when rookie drafts
  land and the run on undrafted rookies follows them.

  Offseason FAAB is a different market from the in-season one where most FAAB
  actually gets spent — these are prices for speculative adds, not for the
  week-9 running back everyone suddenly needs. The window travels with the
  response for the same reason `coverage` travels with manager activity: a
  caller that renders "what he costs" over a window like that, without saying
  so, is overclaiming.

  (An earlier version of this doc gave the span as 2026-05-01 to 2026-07-31.
  That was the *positive-bid* subset. A zero bid is a real winning claim and
  the full range is wider.)
  """

  import Ecto.Query

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Intel.{ObservedLeague, ObservedTransaction}

  @faab 2

  @doc """
  Per-player FAAB prices, plus the sample they rest on.

  Returns

      %{
        window: %{from: ~D[...], to: ~D[...]} | nil,
        leagues: 147,
        players: %{"8161" => %{claims: 10, leagues: 9, median: 85.5, low: 0.2,
                               high: 101.0, failed: 3}}
      }

  `median`/`low`/`high` are percentages of the paying league's budget, rounded
  to one place. `claims` is winning claims and `leagues` how many distinct
  leagues they came from — the honest denominator, since ten claims in one
  league says much less than ten across ten.

  Nothing is filtered by sample size here. A caller decides what it is willing
  to render, but it cannot do that without `claims`, which is why the count
  ships with every entry rather than being left to a follow-up query.
  """
  @spec prices(keyword) :: map
  def prices(opts \\ []) do
    min_claims = Keyword.get(opts, :min_claims, 1)

    %{
      window: window(),
      leagues: league_count(),
      players: players(min_claims)
    }
  end

  defp players(min_claims) do
    # `inner_lateral_join`, not a plain join: the subquery reads `t.adds` from
    # the row beside it. Same shape `Intel.ownership/1` uses to unnest roster
    # arrays, and it drops a claim with no adds rather than counting it.
    from(t in ObservedTransaction,
      join: l in ObservedLeague,
      on: l.id == t.league_id,
      inner_lateral_join: p in fragment("SELECT jsonb_object_keys(?) AS player_id", t.adds),
      on: true,
      where:
        l.waiver_type == @faab and l.waiver_budget > 0 and t.type == "waiver" and
          not is_nil(t.waiver_bid),
      group_by: p.player_id,
      having: fragment("count(*) FILTER (WHERE ? = 'complete')", t.status) >= ^min_claims,
      select: %{
        player_id: p.player_id,
        claims: fragment("count(*) FILTER (WHERE ? = 'complete')", t.status),
        leagues:
          fragment("count(DISTINCT ?) FILTER (WHERE ? = 'complete')", t.league_id, t.status),
        median:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY 100.0 * ? / ?) FILTER (WHERE ? = 'complete')",
            t.waiver_bid,
            l.waiver_budget,
            t.status
          ),
        low:
          fragment(
            "min(100.0 * ? / ?) FILTER (WHERE ? = 'complete')",
            t.waiver_bid,
            l.waiver_budget,
            t.status
          ),
        high:
          fragment(
            "max(100.0 * ? / ?) FILTER (WHERE ? = 'complete')",
            t.waiver_bid,
            l.waiver_budget,
            t.status
          ),
        failed: fragment("count(*) FILTER (WHERE ? = 'failed')", t.status)
      }
    )
    |> Repo.all()
    |> Map.new(fn row ->
      {row.player_id,
       %{
         claims: row.claims,
         leagues: row.leagues,
         median: round_pct(row.median),
         low: round_pct(row.low),
         high: round_pct(row.high),
         failed: row.failed
       }}
    end)
  end

  # The span of the corpus, so a caller can say which market these prices are
  # from. Bounded by the same league filter as the prices themselves —
  # reporting a window that includes leagues whose bids were excluded would
  # describe a sample nobody is looking at.
  defp window do
    from(t in ObservedTransaction,
      join: l in ObservedLeague,
      on: l.id == t.league_id,
      where:
        l.waiver_type == @faab and l.waiver_budget > 0 and t.type == "waiver" and
          t.status == "complete" and not is_nil(t.waiver_bid),
      select: {min(t.created), max(t.created)}
    )
    |> Repo.one()
    |> case do
      {%DateTime{} = from, %DateTime{} = to} ->
        %{from: DateTime.to_date(from), to: DateTime.to_date(to)}

      _ ->
        nil
    end
  end

  defp league_count do
    from(l in ObservedLeague, where: l.waiver_type == @faab and l.waiver_budget > 0)
    |> Repo.aggregate(:count, :id)
  end

  # Decimal out of Postgres, and one place is all the precision a crowd-sourced
  # share of a budget can carry.
  defp round_pct(nil), do: nil
  defp round_pct(%Decimal{} = value), do: value |> Decimal.to_float() |> Float.round(1)
  defp round_pct(value) when is_float(value), do: Float.round(value, 1)
  defp round_pct(value) when is_integer(value), do: value * 1.0
end
