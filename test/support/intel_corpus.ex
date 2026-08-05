defmodule SleeperPlayerApi.IntelCorpus do
  @moduledoc """
  Test-only loader that shapes the harvested JSON corpus under
  `test/support/corpus/` into the plain-map inputs
  `SleeperPlayerApi.Intel.Estimator` expects.

  The corpus directory is gitignored (it's a compiled snapshot of real
  league data) — see `.gitignore` and `docs/leaguemate-intel-estimator.md`
  in the sibling `my-sleeper-app` repo for provenance. This module only
  exists to keep that shaping logic out of the test bodies themselves.
  """

  @corpus_dir Path.join([__DIR__, "corpus"])

  @doc """
  All corpus drafts, shaped for the estimator:

      %{l_d: float, picks: [%{norm: float, player_id: String.t(), manager: String.t() | nil}]}

  `l_d` is the normalized LAST PICK ACTUALLY MADE in the draft (not
  `teams * rounds` capacity) — see estimator moduledoc §1/§4.

  `manager` is the leaguemate's display name when the picking user is one of
  the tracked leaguemates (per `lmusers.json`), otherwise `nil` — those
  picks still count toward the base hazard, they just can't be attributed to
  a manager's seen/took counts.
  """
  @spec drafts() :: [map]
  def drafts do
    rookie_drafts = read_json!("rookie_drafts.json")
    rookie_picks = read_json!("rookie_picks.json")
    uid_to_manager = user_id_to_manager()

    for {draft_id, draft} <- rookie_drafts do
      teams = draft["settings"]["teams"]
      picks = Map.get(rookie_picks, draft_id, [])

      shaped_picks =
        for pick <- picks do
          %{
            norm: normalize(pick["pick_no"], teams),
            player_id: pick["player_id"],
            manager: Map.get(uid_to_manager, pick["picked_by"])
          }
        end

      max_pick_no = picks |> Enum.map(& &1["pick_no"]) |> Enum.max()

      %{l_d: normalize(max_pick_no, teams), picks: shaped_picks}
    end
  end

  defp normalize(pick_no, teams), do: (pick_no - 1) / teams * 12 + 1

  @doc """
  `%{user_id => display_name}` for the tracked leaguemates (`lmusers.json`).
  """
  @spec user_id_to_manager() :: %{String.t() => String.t()}
  def user_id_to_manager do
    "lmusers.json"
    |> read_json!()
    |> Map.new(fn user -> {user["user_id"], user["display_name"]} end)
  end

  @doc "The set of tracked leaguemate display names."
  @spec known_managers() :: MapSet.t(String.t())
  def known_managers do
    user_id_to_manager() |> Map.values() |> MapSet.new()
  end

  @doc """
  FantasyCalc entries for the rookie class only — `maybeDraftInfo.year ==
  2026` — as `{player_id, value}` pairs, ready for
  `SleeperPlayerApi.Intel.Estimator.rookie_class_rank/1`.

  A player with no `maybeDraftInfo` at all (FantasyCalc doesn't cleanly flag
  rookie class membership) is excluded, same as the fixture this is
  reproduced against.
  """
  @spec rookie_class_entries() :: [{String.t(), number}]
  def rookie_class_entries do
    "fc2.json"
    |> read_json!()
    |> Enum.filter(fn entry ->
      match?(%{"maybeDraftInfo" => %{"year" => 2026}}, entry["player"])
    end)
    |> Enum.map(fn entry -> {entry["player"]["sleeperId"], entry["value"]} end)
  end

  @doc """
  The golden fixture (`fixture.json`) — the known-good output the golden
  test reproduces.
  """
  @spec fixture() :: map
  def fixture, do: read_json!("fixture.json")

  @doc """
  `%{pick_number => manager}` straight from the fixture's own `board` array.

  Trade resolution (turning `d13_now.json` + `d13_traded.json` into a
  resolved board) is a separate concern being ported later — this is a
  deliberate shortcut for the golden test, not a stand-in implementation of
  it. See `docs/leaguemate-intel-estimator.md` §9.
  """
  @spec board_from_fixture(map) :: %{integer => String.t()}
  def board_from_fixture(fixture) do
    Map.new(fixture["board"], fn entry -> {entry["pick"], entry["manager"]} end)
  end

  defp read_json!(filename) do
    @corpus_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end
end
