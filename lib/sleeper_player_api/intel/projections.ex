defmodule SleeperPlayerApi.Intel.Projections do
  @moduledoc """
  Sleeper's season projections read as two Now sources for the power
  rankings: projected points, and redraft ADP.

  Ported from the frontend's `src/lib/projections.js`. Pure; each function
  returns a map from Sleeper player id to a number where bigger is better,
  which is the only shape `PowerRankings` asks of a source.

  The rows are Sleeper's `api.sleeper.com/projections/nfl/:season` payload:
  `[%{"player_id" => id, "stats" => %{...}}]`.
  """

  # Sleeper writes 999 for "no ADP in this format".
  @no_adp 999

  # How deep an ADP still counts for anything. A lineup is built from the top
  # couple of hundred players in any real league; past this a player is worth
  # nothing to the ADP source, the same as one with no ADP at all.
  @default_adp_ceiling 300

  @doc "The ADP depth that still counts, from config (default #{@default_adp_ceiling})."
  def adp_ceiling do
    :sleeper_player_api
    |> Application.get_env(SleeperPlayerApi.Intel.PowerRankings, [])
    |> Keyword.get(:adp_ceiling, @default_adp_ceiling)
  end

  @doc """
  A player's projected points under one league's scoring.

  Sleeper's stat keys are the same keys its `scoring_settings` use (`pass_td`,
  `rec`, `bonus_rec_te`, ...), so scoring is a dot product over the league's
  settings. That is what makes this better than the precomputed `pts_ppr`:
  those exist for three stock formats, and a league with TE premium or
  six-point passing touchdowns is none of them.
  """
  def projected_points(stats, scoring_settings) when is_map(stats) and is_map(scoring_settings) do
    Enum.reduce(scoring_settings, 0, fn {key, points}, sum ->
      count = stats[key]
      if is_number(count) and is_number(points), do: sum + count * points, else: sum
    end)
  end

  def projected_points(_stats, _scoring_settings), do: 0

  @doc "Projected points for every row, as `%{player_id => points}`."
  def projection_values(rows, scoring_settings) do
    for %{"player_id" => id} = row <- rows || [], id != nil, into: %{} do
      {to_string(id), projected_points(row["stats"], scoring_settings)}
    end
  end

  @doc """
  Which of Sleeper's redraft ADP columns matches a league. Superflex (and
  two-QB) leagues draft quarterbacks so differently that `adp_2qb` is the only
  honest column for them; otherwise the league's reception scoring picks one.
  """
  def adp_key(superflex, ppr) do
    cond do
      superflex -> "adp_2qb"
      ppr == nil or ppr >= 1 -> "adp_ppr"
      ppr > 0 -> "adp_half_ppr"
      true -> "adp_std"
    end
  end

  @doc """
  ADP as a value, bigger is better: `adp_ceiling - adp`, floored at 0.

  Linear on purpose. It is the "sum the ranks" reading Dynasty Daddy
  describes for its ADP model, flipped so the best lineup is the biggest
  number, which is what every other source here does.
  """
  def adp_values(rows, superflex, ppr) do
    key = adp_key(superflex, ppr)
    ceiling = adp_ceiling()

    Enum.reduce(rows || [], %{}, fn row, by_id ->
      id = row["player_id"]
      adp = get_in(row, ["stats", key])

      if id != nil and is_number(adp) and adp < @no_adp,
        do: Map.put(by_id, to_string(id), max(0, ceiling - adp)),
        else: by_id
    end)
  end
end
