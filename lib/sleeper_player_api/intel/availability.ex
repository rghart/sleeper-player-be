defmodule SleeperPlayerApi.Intel.Availability do
  @moduledoc """
  Builds the `/availability` response shape (plan `docs/leaguemate-intel.md`
  §3e, §3f step 4), given already-gathered plain data. No Ecto, no HTTP —
  `SleeperPlayerApi.Intel` is the adapter that fetches/stores that data;
  this module (like `Estimator`) only shapes and computes.

  The response shape is deliberately the fixture's shape
  (`src/Prototypes/rankListIntel/fixture.json` in the `my-sleeper-app`
  sibling repo) — see that file and
  `docs/leaguemate-intel-estimator.md` for the field-by-field contract this
  reproduces. All math is delegated to `SleeperPlayerApi.Intel.Estimator`;
  this module's job is board resolution (via `PickOwnership`) and shaping
  the estimator's output plus the corpus aggregates into the fixture's
  exact structure.

  ## Failure behaviour (§3e)

  Pick ownership must always be resolvable for the response to mean
  anything — a `PickOwnership` failure (an unsupported draft type) returns
  `{:error, reason}` rather than a degraded response, because serving
  survival numbers computed from unresolved ownership is the one thing the
  plan says this feature must never do.

  A missing/empty corpus is different: it's an honest "no reads yet", not a
  correctness violation, so it still returns `{:ok, response}` with
  `targets: []` and `corpusDrafts: 0` rather than erroring — the board
  (trade resolution) doesn't depend on the corpus at all.
  """

  alias SleeperPlayerApi.Intel.{Estimator, PickOwnership}

  @signal_threshold %{min_drafts: 8, min_times: 3}

  @doc """
  Builds the full response map (atom-keyed, snake_case — the JSON view is
  responsible for the camelCase rename, same split as `PlayerJSON`).

  `input` is:

      %{
        league_name: String.t(),
        draft_id: integer,
        teams: pos_integer,
        rounds: pos_integer,
        draft_type: String.t(),
        slot_to_roster_id: %{integer => integer},
        picks_made: [%{pick_no: integer, player_id: String.t() | nil}],
        traded_picks: %{{integer, integer} => integer},
        roster_to_user: %{integer => integer},
        user_id_to_manager: %{integer => String.t()},
        my_user_id: integer,
        at_pick: integer | nil,
        limit: pos_integer,
        corpus: [Estimator draft map],       # already filtered to `status == "complete"`,
                                              # excluding the draft being analyzed
        candidate_lookup: %{String.t() => %{name: String.t() | nil, position: String.t() | nil}},
        market_rank: %{String.t() => pos_integer},
        raw_picks: %{{String.t(), String.t()} => [String.t()]},
        eligible_ids: MapSet.t(String.t()) | nil    # optional; see "Which players become targets?" below
      }

  ## Which players become `targets`? (plan §3f step 4 — underspecified)

  Base rule: corpus players not yet drafted in the live draft, ordered by
  `leagueAdp` ascending, capped at `limit`. `eligible_ids`, when given,
  additionally restricts the candidate pool to that set before ordering —
  the adapter (`SleeperPlayerApi.Intel.availability/2`) uses this to drop
  non-fantasy positions (a corpus rookie draft's pick pool isn't
  exclusively QB/RB/WR/TE; an LB with a stray 5-draft sample otherwise
  outranks every real target by raw ADP). `nil` (the default, and what
  every test in `availability_test.exs` uses) means no restriction.

  Returns `{:ok, response}` or `{:error, reason}` — see moduledoc.
  """
  @spec build(map) :: {:ok, map} | {:error, term}
  def build(input) do
    current_pick = input[:at_pick] || next_pick(input.picks_made)
    last_pick = input.teams * input.rounds

    with {:ok, board_rosters} <-
           PickOwnership.resolve_board(
             current_pick..last_pick,
             input.teams,
             input.draft_type,
             input.slot_to_roster_id,
             input.traded_picks
           ) do
      known_managers = input.user_id_to_manager |> Map.values() |> MapSet.new()

      board =
        Enum.map(board_rosters, fn %{pick: pick, roster_id: roster_id} ->
          user_id = Map.get(input.roster_to_user, roster_id)
          manager = user_id && Map.get(input.user_id_to_manager, user_id)

          %{
            pick: pick,
            manager: manager,
            mine: user_id != nil and user_id == input.my_user_id,
            drafts: if(manager, do: Estimator.manager_seen(input.corpus, manager), else: 0)
          }
        end)

      board_owner = Map.new(board, fn b -> {b.pick, b.manager} end)
      my_picks = board |> Enum.filter(& &1.mine) |> Enum.map(& &1.pick)

      picked_player_ids =
        input.picks_made |> Enum.map(& &1.player_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

      targets =
        build_targets(
          input,
          current_pick,
          last_pick,
          board_owner,
          known_managers,
          picked_player_ids
        )

      {:ok,
       %{
         league: input.league_name,
         draft_id: input.draft_id,
         current_pick: current_pick,
         last_pick: last_pick,
         teams: input.teams,
         rounds: input.rounds,
         my_picks: my_picks,
         corpus_drafts: length(input.corpus),
         board: board,
         targets: targets,
         signal_threshold: @signal_threshold,
         traded_picks_applied: true,
         hazard: hazard_description()
       }}
    end
  end

  defp next_pick([]), do: 1
  defp next_pick(picks_made), do: (picks_made |> Enum.map(& &1.pick_no) |> Enum.max()) + 1

  # ---------------------------------------------------------------------
  # Target selection (plan §3f step 4 "which players become targets?" —
  # underspecified; the choice made here: corpus players still on the
  # board in the live draft, ordered by league ADP, capped at `limit`)
  # ---------------------------------------------------------------------

  defp build_targets(input, current_pick, last_pick, board_owner, known_managers, picked) do
    if input.corpus == [] do
      []
    else
      eligible_ids = Map.get(input, :eligible_ids)

      candidate_ids =
        for draft <- input.corpus,
            pick <- draft.picks,
            not MapSet.member?(picked, pick.player_id),
            is_nil(eligible_ids) or MapSet.member?(eligible_ids, pick.player_id),
            do: pick.player_id

      candidate_ids
      |> Enum.uniq()
      |> Enum.map(fn player_id ->
        events = Estimator.player_events(input.corpus, player_id)
        {player_id, Estimator.adp_summary(events)}
      end)
      |> Enum.reject(fn {_id, summary} -> is_nil(summary) end)
      |> Enum.sort_by(fn {_id, summary} -> summary.adp end)
      |> Enum.take(input.limit)
      |> Enum.map(fn {player_id, summary} ->
        build_target(
          input,
          player_id,
          summary,
          current_pick,
          last_pick,
          board_owner,
          known_managers
        )
      end)
    end
  end

  defp build_target(
         input,
         player_id,
         summary,
         current_pick,
         last_pick,
         board_owner,
         known_managers
       ) do
    hazard = Estimator.base_hazard(input.corpus, player_id)
    base_rate = Estimator.base_rate(input.corpus, player_id)

    mult_fun = fn manager ->
      seen = Estimator.manager_seen(input.corpus, manager)
      took = Estimator.manager_took(input.corpus, manager, player_id)
      Estimator.multiplier(seen, took, base_rate)
    end

    board_mult_fun = fn pick -> mult_fun.(Map.get(board_owner, pick)) end

    by_pick =
      for pick <- current_pick..(last_pick + 1), into: %{} do
        base_survival = Estimator.base_survival(hazard, current_pick, pick)
        adj_survival = Estimator.adjusted_survival(hazard, current_pick, pick, board_mult_fun)

        threats =
          Estimator.threats(
            hazard,
            current_pick,
            pick,
            board_owner,
            known_managers,
            mult_fun,
            fn manager -> Estimator.manager_seen(input.corpus, manager) end,
            fn manager -> Estimator.manager_took(input.corpus, manager, player_id) end
          )

        {pick,
         %{
           adj_survival: round3(adj_survival),
           base_survival: round3(base_survival),
           threats: Enum.map(threats, &round_threat/1)
         }}
      end

    market_pick = Map.get(input.market_rank, player_id)
    adp_gap = Estimator.adp_gap(summary.adp, market_pick)

    lookup = Map.get(input.candidate_lookup, player_id, %{})

    %{
      id: player_id,
      name: Map.get(lookup, :name),
      position: Map.get(lookup, :position),
      league_adp: round1(summary.adp),
      sd: round1(summary.sd),
      n: summary.n,
      min: round1(summary.min),
      max: round1(summary.max),
      by_pick: by_pick,
      per_manager: per_manager(input, player_id),
      market_pick: market_pick,
      adp_gap: adp_gap,
      notable: notable(input, player_id, board_owner, summary.adp)
    }
  end

  defp round_threat(threat), do: %{threat | prob: round3(threat.prob)}

  defp round3(nil), do: nil
  defp round3(x), do: Float.round(x * 1.0, 3)

  defp round1(nil), do: nil
  defp round1(x), do: Float.round(x * 1.0, 1)

  # ---------------------------------------------------------------------
  # Per-manager ADP + "notable" (plan §3 Frontend / §4e-bis)
  # ---------------------------------------------------------------------

  defp per_manager(input, player_id) do
    for manager <- Enum.sort(MapSet.to_list(known_managers(input))),
        took = Estimator.manager_took(input.corpus, manager, player_id),
        took > 0 do
      seen = Estimator.manager_seen(input.corpus, manager)
      events = manager_events(input.corpus, manager, player_id)
      adp = Enum.sum(events) / length(events)

      %{
        manager: manager,
        times: took,
        of: seen,
        adp: round1(adp),
        picks: raw_picks_for(input, manager, player_id)
      }
    end
    |> Enum.sort_by(& &1.manager)
  end

  defp known_managers(input), do: input.user_id_to_manager |> Map.values() |> MapSet.new()

  defp manager_events(corpus, manager, player_id) do
    for draft <- corpus,
        pick <- draft.picks,
        pick.player_id == player_id,
        pick.manager == manager,
        do: pick.norm
  end

  # `raw_picks` is the caller-supplied `%{{manager, player_id} => [String.t()]}`
  # of already-formatted "round.slot@overall" strings — see
  # `SleeperPlayerApi.Intel.manager_pick_strings/1`. Threaded through `input`
  # because it needs `round`/`draft_slot`/`pick_no`, which the
  # Estimator-shaped corpus deliberately doesn't carry.
  defp raw_picks_for(input, manager, player_id) do
    Map.get(input.raw_picks, {manager, player_id}, [])
  end

  defp notable(input, player_id, board_owner, league_adp) do
    input
    |> per_manager(player_id)
    |> Enum.filter(fn m ->
      m.of >= @signal_threshold.min_drafts and m.times >= @signal_threshold.min_times
    end)
    |> Enum.sort_by(&{-&1.times, -&1.of})
    |> case do
      [] ->
        false

      [top | _] ->
        %{
          manager: top.manager,
          adp: top.adp,
          times: top.times,
          of: top.of,
          still_to_pick: still_to_pick?(board_owner, top.manager),
          delta: round1(top.adp - league_adp)
        }
    end
  end

  defp still_to_pick?(board_owner, manager) do
    board_owner |> Map.values() |> Enum.any?(&(&1 == manager))
  end

  defp hazard_description do
    %{
      estimator: "kaplan-meier + gaussian-kernel events",
      bandwidth: "max(0.6, min(1.5, 0.4*sd))",
      censoring: "risk set excludes drafts shorter than the pick",
      manager_weight: "n/(n+12) confidence weight on the shrunk multiplier"
    }
  end
end
