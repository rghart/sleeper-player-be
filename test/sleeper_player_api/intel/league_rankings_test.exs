defmodule SleeperPlayerApi.Intel.LeagueRankingsTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.LeagueRankings

  # Golden fixtures produced by the frontend's own `rankLeague` over real,
  # anonymised leagues; see capture.mjs beside them for how, and why they are
  # safe to commit. The port is correct when it reproduces `expected` from
  # `inputs`. Regenerate them with the script, never from this code: a golden
  # file regenerated from the code it checks proves nothing.
  @fixture_dir Path.expand("../../support/fixtures/power_rankings", __DIR__)
  @fixtures @fixture_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".json"))
            |> Enum.sort()

  # Floats are compared relatively. The JS and the port add in the same order
  # where it matters, but the projection dot product runs over a map, whose
  # iteration order differs between the two, so the last bits can too.
  @tolerance 1.0e-9

  test "there are fixtures to check against" do
    assert length(@fixtures) >= 3
  end

  for file <- @fixtures do
    @file_name file

    test "reproduces the frontend's rankings for #{Path.rootname(file)}" do
      fixture = @fixture_dir |> Path.join(@file_name) |> File.read!() |> Jason.decode!()
      inputs = fixture["inputs"]

      actual =
        LeagueRankings.rank(%{
          league: inputs["league"],
          rosters: inputs["rosters"],
          users: inputs["users"],
          player_info: inputs["playerInfo"],
          ktc: inputs["inputs"]["ktc"],
          fc: inputs["inputs"]["fc"],
          traded_picks: inputs["inputs"]["tradedPicks"],
          projections: inputs["inputs"]["projections"],
          current_draft_complete: inputs["currentDraftComplete"],
          draft: inputs["draft"]
        })

      assert mismatches(camelize(actual), fixture["expected"], "$") == []
    end
  end

  describe "rank/1" do
    test "is nil without KTC, which the Future score cannot do without" do
      fixture = load(hd(@fixtures))["inputs"]

      assert LeagueRankings.rank(%{
               league: fixture["league"],
               rosters: fixture["rosters"],
               player_info: fixture["playerInfo"],
               ktc: nil
             }) == nil
    end

    test "leaves picks out entirely without the traded-picks list" do
      # Crediting every team with its own picks would be a claim nothing here
      # can back, so no picks are counted rather than the default set.
      fixture = load(hd(@fixtures))["inputs"]

      teams =
        LeagueRankings.rank(%{
          league: fixture["league"],
          rosters: fixture["rosters"],
          player_info: fixture["playerInfo"],
          ktc: fixture["inputs"]["ktc"],
          traded_picks: nil
        })

      assert Enum.all?(teams, &(&1.picks == nil and &1.future_detail.picks == []))
      # Without projections or FantasyCalc, KTC is the only Now source.
      assert Enum.all?(teams, &(Map.keys(&1.now) |> Enum.sort() == [:blend, :ktc]))
    end
  end

  defp load(file), do: @fixture_dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  # The port speaks snake_case atoms; the JS camelCase strings.
  defp camelize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {camel_key(k), camelize(v)} end)

  defp camelize(list) when is_list(list), do: Enum.map(list, &camelize/1)
  defp camelize(other), do: other

  defp camel_key(key) do
    [first | rest] = key |> to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  # Every path where the two differ, so a failure says where, not just that.
  defp mismatches(a, b, path) when is_map(a) and is_map(b) do
    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))
    Enum.flat_map(Enum.sort(keys), &mismatches(Map.get(a, &1), Map.get(b, &1), "#{path}.#{&1}"))
  end

  defp mismatches(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    [a, b]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> mismatches(x, y, "#{path}[#{i}]") end)
  end

  defp mismatches(a, b, path) when is_number(a) and is_number(b) do
    if abs(a - b) <= @tolerance * Enum.max([1, abs(a), abs(b)]), do: [], else: [{path, a, b}]
  end

  defp mismatches(a, a, _path), do: []
  defp mismatches(a, b, path), do: [{path, a, b}]
end
