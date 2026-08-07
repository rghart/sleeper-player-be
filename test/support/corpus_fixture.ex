defmodule SleeperPlayerApi.CorpusFixture do
  @moduledoc """
  Loads the harvested rookie-draft corpus straight from
  `test/support/corpus/*.json` into the plain map shape
  `SleeperPlayerApi.Intel.Estimator` takes — no Repo, no Postgres, no seeding.

  The estimator and `Intel.Calibration` are both pure, so measuring them does
  not need a database; going through one would only add a fixed cost to every
  leave-one-out pass. `Intel.drafts_corpus/2` remains the production path.

  The corpus itself is gitignored (the repo is public and this is a
  behavioural profile of thirteen real, named people — see the estimator
  memory), so anything using this must be tagged `:corpus`.
  """

  @corpus_dir Path.expand("corpus", __DIR__)

  @doc """
  Every completed rookie draft as `%{l_d: float, picks: [%{norm, player_id,
  manager}]}`.

  `l_d` is the normalized **last pick actually made**, not `teams * rounds` —
  that distinction is the whole of §3g's censoring fix, and it is what lets a
  3-round draft stop voting on what happens at pick 39.
  """
  def drafts do
    users = read!("lmusers.json")
    manager_by_id = Map.new(users, &{&1["user_id"], &1["display_name"]})

    picks_by_draft = read!("rookie_picks.json")

    # Both corpus files are objects keyed by draft id, not arrays.
    read!("rookie_drafts.json")
    |> Map.values()
    |> Enum.map(fn draft ->
      teams = get_in(draft, ["settings", "teams"]) || 12
      picks = Map.get(picks_by_draft, draft["draft_id"], [])
      build(picks, teams, manager_by_id)
    end)
    |> Enum.reject(&(&1.picks == []))
  end

  defp build(picks, teams, manager_by_id) do
    normalized =
      Enum.map(picks, fn pick ->
        %{
          norm: normalize(pick["pick_no"], teams),
          player_id: pick["player_id"],
          manager: Map.get(manager_by_id, pick["picked_by"])
        }
      end)

    last = normalized |> Enum.map(& &1.norm) |> Enum.max(fn -> 0.0 end)
    %{l_d: last, picks: normalized}
  end

  defp normalize(pick_no, teams), do: (pick_no - 1) / teams * 12 + 1

  defp read!(name), do: @corpus_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
end
