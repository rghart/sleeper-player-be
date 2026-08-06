defmodule SleeperPlayerApiWeb.IntelJSON do
  @moduledoc """
  Renders `SleeperPlayerApi.Intel.league_intel/2` into `/intel`'s response
  shape (plan §3e) — camelCase keys, same split (snake_case context,
  camelCase view) as `AvailabilityJSON`.

  `corpus.membershipSource` is `"live"` when `managers` came from a live
  `GET /league/:id/users` call (the normal case) or `"derived"` when that
  call failed and the list fell back to observed-participation only — see
  `Intel.league_intel/2`'s "Failure behaviour" doc. A `"derived"` list may
  be missing 0-draft members.
  """

  def show(%{intel: i}) do
    %{
      managers: Enum.map(i.managers, &manager/1),
      corpus: %{
        drafts: i.corpus.drafts,
        picks: i.corpus.picks,
        lastCrawledAt: i.corpus.last_crawled_at,
        membershipSource: i.corpus.membership_source
      }
    }
  end

  defp manager(m) do
    %{
      userId: m.user_id,
      displayName: m.display_name,
      leaguesCount: m.leagues_count,
      draftsCount: m.drafts_count,
      draftsComplete: m.drafts_complete,
      tendencies: tendencies(m.tendencies)
    }
  end

  defp tendencies(t) do
    %{
      crushes: Enum.map(t.crushes, &crush/1),
      positionLean: Enum.map(t.position_lean, &position_lean/1),
      reachVsAdp: t.reach_vs_adp
    }
  end

  defp crush(c) do
    %{playerId: c.player_id, name: c.name, position: c.position, times: c.times, of: c.of}
  end

  defp position_lean(p) do
    %{position: p.position, picks: p.picks, share: p.share}
  end
end
