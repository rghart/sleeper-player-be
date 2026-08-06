defmodule SleeperPlayerApiWeb.AvailabilityJSON do
  @moduledoc """
  Renders `SleeperPlayerApi.Intel.availability/2`'s response into the exact
  shape `src/Prototypes/rankListIntel/fixture.json` (in the `my-sleeper-app`
  sibling repo) already established — camelCase keys, even though Elixir is
  snake_case throughout the context/estimator layer, per plan §3f step 4:
  "keep the JSON keys camelCase exactly as the fixture has them... the
  frontend swap is meant to be a fetch call, not a rewrite."
  """

  def show(%{availability: a}) do
    %{
      league: a.league,
      draftId: a.draft_id,
      currentPick: a.current_pick,
      lastPick: a.last_pick,
      teams: a.teams,
      rounds: a.rounds,
      myPicks: a.my_picks,
      corpusDrafts: a.corpus_drafts,
      board: Enum.map(a.board, &board_entry/1),
      targets: Enum.map(a.targets, &target/1),
      signalThreshold: %{
        minDrafts: a.signal_threshold.min_drafts,
        minTimes: a.signal_threshold.min_times
      },
      tradedPicksApplied: a.traded_picks_applied,
      hazard: %{
        estimator: a.hazard.estimator,
        bandwidth: a.hazard.bandwidth,
        censoring: a.hazard.censoring,
        managerWeight: a.hazard.manager_weight
      }
    }
  end

  defp board_entry(b) do
    %{pick: b.pick, manager: b.manager, mine: b.mine, drafts: b.drafts}
  end

  defp target(t) do
    %{
      id: t.id,
      name: t.name,
      position: t.position,
      leagueAdp: t.league_adp,
      sd: t.sd,
      n: t.n,
      min: t.min,
      max: t.max,
      byPick: by_pick(t.by_pick),
      perManager: Enum.map(t.per_manager, &per_manager/1),
      marketPick: t.market_pick,
      adpGap: t.adp_gap,
      notable: notable(t.notable)
    }
  end

  defp by_pick(by_pick) do
    Map.new(by_pick, fn {pick, entry} ->
      {Integer.to_string(pick),
       %{
         adjSurvival: entry.adj_survival,
         baseSurvival: entry.base_survival,
         threats: Enum.map(entry.threats, &threat/1)
       }}
    end)
  end

  defp threat(t) do
    %{manager: t.manager, pick: t.pick, prob: t.prob, drafts: t.drafts, tookCount: t.tookCount}
  end

  defp per_manager(m) do
    %{manager: m.manager, times: m.times, of: m.of, adp: m.adp, picks: m.picks}
  end

  defp notable(false), do: false

  defp notable(n) do
    %{
      manager: n.manager,
      adp: n.adp,
      times: n.times,
      of: n.of,
      stillToPick: n.still_to_pick,
      delta: n.delta
    }
  end
end
