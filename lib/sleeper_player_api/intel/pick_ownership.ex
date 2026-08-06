defmodule SleeperPlayerApi.Intel.PickOwnership do
  @moduledoc """
  Trade-resolved pick ownership (plan `docs/leaguemate-intel.md` §3d, §4f).

  Pure — no Ecto, no HTTP. Given a pick number and the draft's own settings
  (teams, draft type, `slot_to_roster_id`) plus its traded-pick ledger,
  resolves which roster actually owns that pick *right now*, folding in
  every trade instead of trusting the original snake/linear draft order.

      round      = ceil(pick_no / teams)
      slot       = ((pick_no - 1) mod teams) + 1          # LINEAR
      roster     = slot_to_roster_id[slot]
      true_owner = traded_picks[{round, roster}] || roster

  **Caveat the plan doesn't spell out**: that formula assumes a *linear*
  draft. District 13 (the plan's own acceptance case, §4f) is `type:
  "linear"`, but Sleeper also supports `"snake"`, where the slot order
  reverses on even rounds. Applying the linear formula to a snake draft
  would attribute picks to the wrong manager — the one thing §4f says this
  feature must never do. Snake is cheap to handle explicitly, so it's
  handled here; any other draft type (`"auction"`, or anything unrecognized)
  fails loudly with `{:error, {:unsupported_draft_type, type}}` rather than
  silently guessing.
  """

  @doc """
  `round = ceil(pick_no / teams)`.
  """
  @spec round_of(pos_integer, pos_integer) :: pos_integer
  def round_of(pick_no, teams), do: div(pick_no + teams - 1, teams)

  @doc """
  The draft slot (1-indexed) that's on the clock at `pick_no`, for a
  `"linear"` or `"snake"` draft. `{:error, {:unsupported_draft_type,
  type}}` for anything else — see moduledoc.
  """
  @spec slot_of(pos_integer, pos_integer, String.t()) ::
          {:ok, pos_integer} | {:error, {:unsupported_draft_type, String.t()}}
  def slot_of(pick_no, teams, "linear") do
    {:ok, rem(pick_no - 1, teams) + 1}
  end

  def slot_of(pick_no, teams, "snake") do
    position_in_round = rem(pick_no - 1, teams) + 1
    round = round_of(pick_no, teams)

    slot =
      if rem(round, 2) == 1 do
        position_in_round
      else
        teams - position_in_round + 1
      end

    {:ok, slot}
  end

  def slot_of(_pick_no, _teams, type), do: {:error, {:unsupported_draft_type, type}}

  @doc """
  Resolves the roster that owns `pick_no` *after* trades, per the formula in
  the moduledoc.

  `slot_to_roster_id` is `%{integer => integer}` (slot -> roster_id — note
  Sleeper's own JSON has string keys; callers normalize before calling
  this). `traded_picks` is `%{{round, original_roster_id} => new_roster_id}`
  — a pick not present in that map is still owned by its original roster.

  A slot missing from `slot_to_roster_id` (empty map, or a hole in it) is a
  data problem — the crawler couldn't populate the mapping, or Sleeper
  hasn't assigned that slot yet — not a crash: `{:error, {:unmapped_slot,
  slot}}`, same shape as the unsupported-draft-type error, rather than
  `Map.fetch!/2` raising `KeyError` and turning one bad row into a 500 (hit
  in production against a real draft whose `slot_to_roster_id` was `%{}`).
  """
  @spec resolve_roster(pos_integer, pos_integer, String.t(), %{integer => integer}, %{
          {integer, integer} => integer
        }) ::
          {:ok, integer}
          | {:error, {:unsupported_draft_type, String.t()} | {:unmapped_slot, pos_integer}}
  def resolve_roster(pick_no, teams, draft_type, slot_to_roster_id, traded_picks) do
    with {:ok, slot} <- slot_of(pick_no, teams, draft_type),
         {:ok, original_roster} <- fetch_roster(slot_to_roster_id, slot) do
      round = round_of(pick_no, teams)
      true_roster = Map.get(traded_picks, {round, original_roster}, original_roster)
      {:ok, true_roster}
    end
  end

  defp fetch_roster(slot_to_roster_id, slot) do
    case Map.fetch(slot_to_roster_id, slot) do
      {:ok, roster_id} -> {:ok, roster_id}
      :error -> {:error, {:unmapped_slot, slot}}
    end
  end

  @doc """
  Resolves every pick in `pick_range`, roster only (no manager names — the
  caller joins roster -> user -> display name, since that mapping is a
  league concern this module deliberately knows nothing about).

  Returns `{:ok, [%{pick: integer, roster_id: integer}]}` or the same
  `{:error, ...}` `slot_of/3` would give, short-circuiting on the first
  unresolved pick (the draft type is one property of the whole draft, so if
  it fails once it fails for every pick).
  """
  @spec resolve_board(Enumerable.t(), pos_integer, String.t(), %{integer => integer}, %{
          {integer, integer} => integer
        }) :: {:ok, [%{pick: integer, roster_id: integer}]} | {:error, term}
  def resolve_board(pick_range, teams, draft_type, slot_to_roster_id, traded_picks) do
    Enum.reduce_while(pick_range, {:ok, []}, fn pick_no, {:ok, acc} ->
      case resolve_roster(pick_no, teams, draft_type, slot_to_roster_id, traded_picks) do
        {:ok, roster_id} -> {:cont, {:ok, [%{pick: pick_no, roster_id: roster_id} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
