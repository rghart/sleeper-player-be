defmodule SleeperPlayerApiWeb.ManagerActivityJSON do
  @moduledoc """
  Renders `SleeperPlayerApi.Intel.manager_activity/2` — camelCase keys, same
  snake_case-context / camelCase-view split as `AvailabilityJSON` and
  `IntelJSON`.

  `coverage` is not decoration and must not be dropped by a caller looking to
  slim the payload. "5 trades" across 42 leagues and "5 trades" across 4 are
  different claims, and this feature has shipped a figure without its sample
  size four separate times.

  `adds`/`drops` stay keyed by player id exactly as Sleeper sends them, with
  a sibling `players` map for the names — rather than inlining a name per
  entry, which would repeat it for every transaction touching the same player.
  """

  def show(%{activity: a}) do
    %{
      transactions: Enum.map(a.transactions, &transaction/1),
      players: Map.new(a.players, fn {id, p} -> {id, %{name: p.name, position: p.position}} end),
      coverage: %{
        leaguesSeen: a.coverage.leagues_seen,
        leaguesKnown: a.coverage.leagues_known,
        lastCrawledAt: a.coverage.last_crawled_at
      }
    }
  end

  defp transaction(t) do
    %{
      id: t.id,
      leagueId: t.league_id,
      week: t.week,
      type: t.type,
      # `"failed"` rows are served, not filtered. A failed waiver claim is a
      # revealed preference nobody else in that league can see; the client
      # labels it rather than the API hiding it.
      status: t.status,
      created: t.created,
      creator: t.creator,
      participantIds: t.participant_ids,
      adds: t.adds || %{},
      drops: t.drops || %{},
      draftPicks: t.draft_picks || [],
      waiverBid: t.waiver_bid
    }
  end
end
