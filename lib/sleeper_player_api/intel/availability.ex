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

  An `at_pick` outside the draft is also a hard failure —
  `{:error, {:pick_out_of_range, at_pick, last_pick}}` — for the same
  reason in a smaller way: the empty board and empty `byPick` it used to
  produce are indistinguishable from an honest "nothing left to read".
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
        eligible_ids: MapSet.t(String.t()) | nil,   # optional; see "Which players become targets?" below
        ownership: %{                               # optional; see `per_manager/2`
          owns: %{{String.t(), String.t()} => pos_integer},
          leagues: %{String.t() => pos_integer}
        }
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

    with :ok <- check_range(input[:at_pick], last_pick),
         {:ok, board_rosters} <-
           PickOwnership.resolve_board(
             # `//1` is load-bearing: a bare `a..b` where a > b silently
             # becomes a DESCENDING range. Once a draft finishes,
             # `current_pick` is `last_pick + 1`, so `49..48` yielded a board
             # of [49, 48] — one pick that never existed and one already
             # made — instead of the empty board that says "no picks left".
             # Found by hitting the endpoint against the real, now-completed
             # District 13 draft; every test used a mid-draft board.
             current_pick..last_pick//1,
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

  # Only an explicitly asked-for pick is range-checked; the derived one is
  # `last_pick + 1` at most, by construction.
  #
  # The accepted range is `1..last_pick + 1`, one past the end on purpose:
  # that is what a finished draft reports as its own `current_pick`, and
  # the frontend's pick selector echoes the response's `currentPick` back
  # as `at_pick`. Refusing it would 422 every completed draft.
  #
  # Without this, `at_pick=999` was a 200 carrying an empty board and
  # empty `byPick` — the UI renders that as "no read", which is honest
  # about the answer but hides that the question was nonsense. Below 1 it
  # did fail, but as `{:unmapped_slot, 0}` raised by `PickOwnership` for
  # draft slot 0, which describes an internal lookup rather than the
  # caller's mistake.
  defp check_range(nil, _last_pick), do: :ok

  defp check_range(at_pick, last_pick) when at_pick in 1..(last_pick + 1)//1, do: :ok

  defp check_range(at_pick, last_pick), do: {:error, {:pick_out_of_range, at_pick, last_pick}}

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

    # Survival stays server-side for both figures. It is tempting to send
    # only `hazards` and let the client derive survival from it, which is
    # smaller again - but §3g's whole point is that one estimator serves the
    # headline and the stations so the gauntlet telescopes exactly to the
    # chip. Deriving it a second time on the client is precisely the second,
    # inconsistent computation that fixed.
    #
    # `//1` for the same reason as the board range above.
    by_pick =
      for pick <- current_pick..(last_pick + 1)//1, into: %{} do
        {pick,
         %{
           adj_survival:
             round3(Estimator.adjusted_survival(hazard, current_pick, pick, board_mult_fun)),
           base_survival: round3(Estimator.base_survival(hazard, current_pick, pick))
         }}
      end

    # One entry per pick rather than a threat list per target pick - see
    # `Estimator.hazards/6` on why the latter was 22x larger than its own
    # content. The top of the range is `last_pick`, not `last_pick + 1`:
    # by_pick runs one past the end so the gauntlet can read "survival after
    # this pick", but no threat ever sits at that extra pick.
    hazards =
      hazard
      |> Estimator.hazards(current_pick, last_pick, board_owner, known_managers, mult_fun)
      |> Enum.map(fn h -> %{h | prob: round3(h.prob)} end)

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
      hazards: hazards,
      per_manager: per_manager(input, player_id),
      market_pick: market_pick,
      adp_gap: adp_gap,
      notable: notable(input, player_id, board_owner, summary.adp)
    }
  end

  defp round3(nil), do: nil
  defp round3(x), do: Float.round(x * 1.0, 3)

  defp round1(nil), do: nil
  defp round1(x), do: Float.round(x * 1.0, 1)

  # ---------------------------------------------------------------------
  # Per-manager ADP + "notable" (plan §3 Frontend / §4e-bis)
  # ---------------------------------------------------------------------

  # An entry appears when a manager has *either* drafted the player or owns
  # him somewhere now. Those two populations barely overlap: measured
  # 2026-08-09 across the real corpus, 94% of (manager, player) ownership
  # pairs never appear in a crawled draft at all, because the player arrived
  # by trade or waiver or in a league whose draft was never crawled. Listing
  # only the drafters would drop most of what the rosters know.
  #
  # `adp`/`picks` stay nil/[] for an ownership-only entry rather than being
  # faked from the ownership count — the draft read and the holdings read are
  # different questions and §4e-bis's whole point is not to conflate two
  # numbers that look alike.
  defp per_manager(input, player_id) do
    ownership = Map.get(input, :ownership, %{owns: %{}, leagues: %{}})
    managers = Enum.sort(MapSet.to_list(known_managers(input)))

    # `of_leagues` is deliberately NOT bound as a comprehension filter. An
    # assignment used as a filter drops the row when the value is falsy, and
    # this one is nil for any manager we hold no roster data for — which
    # silently removed managers who had drafted the player from the list
    # entirely. It is read in the body instead, where nil is just nil.
    for manager <- managers,
        took = Estimator.manager_took(input.corpus, manager, player_id),
        owns = Map.get(ownership.owns, {manager, player_id}, 0),
        took > 0 or owns > 0 do
      seen = Estimator.manager_seen(input.corpus, manager)
      events = manager_events(input.corpus, manager, player_id)

      %{
        manager: manager,
        times: took,
        of: seen,
        adp: if(events == [], do: nil, else: round1(Enum.sum(events) / length(events))),
        picks: raw_picks_for(input, manager, player_id),
        owns: owns,
        of_leagues: Map.get(ownership.leagues, manager)
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
