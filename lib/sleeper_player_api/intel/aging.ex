defmodule SleeperPlayerApi.Intel.Aging do
  @moduledoc """
  Who is past their position's age cliff, and how much of a lineup that is
  (docs/dynasty-engine.md, M2).

  One set of cutoffs serves two questions, so "aging" and "sell" are the same
  idea tuned in one place:

    * `SellSignals` lists players past their cutoff on teams that are not
      contending.
    * `lineup_share/2` says how much of a contender's starting value is past
      it, and `aging?/2` flags the team when that share is high.

  The share is measured on **projected points** where there are any: the
  question is how much of this season's production comes from players about
  to decline. KeepTradeCut is the fallback, but a poor measure of this,
  because it already discounts age - a lineup of veterans looks weak by KTC
  and drops out of the contender tiers before the flag can apply.

  `lineup_share/2` is told which lineup to read; `aging_lineup/1` picks it.

  The cutoffs are per position because age curves are: a 31-year-old
  quarterback is in his prime and a 27-year-old running back is not, which
  is why an average age across positions would blur exactly the signal
  wanted. They are starting values from the spec, in config, to be tuned
  against real leagues.

  Ages are Sleeper's whole-year `age`, from the player dump.
  """

  @default_cutoffs %{"QB" => 33, "RB" => 26, "WR" => 29, "TE" => 30}
  @default_aging_share 0.25

  @doc "The age at which each position is past its cliff, from config."
  def cutoffs do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cutoffs, @default_cutoffs)
  end

  @doc "The share of starting value past the cliff that makes a contender aging, from config."
  def aging_share do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:aging_share, @default_aging_share)
  end

  @doc """
  Whether a player is at or past his position's cutoff. False for a position
  with no cutoff (K, DEF) or an unknown age: nothing is claimed without one.
  """
  def past_cutoff?(nil), do: false

  def past_cutoff?(info) do
    cutoff = cutoffs()[info["position"]]
    age = info["age"]
    is_integer(cutoff) and is_number(age) and age >= cutoff
  end

  @doc """
  The share of a lineup's value held by starters past their cutoff, 0 to 1,
  or nil for a lineup worth nothing (a league that has not drafted).

  `lineup` is one source's `%{starters: [...], total: ...}` from
  `PowerRankings.best_lineup/4`.
  """
  def lineup_share(nil, _player_info), do: nil

  def lineup_share(%{starters: starters, total: total}, player_info) do
    if total > 0 do
      aged =
        starters
        |> Enum.filter(&(&1.player_id && past_cutoff?(player_info[&1.player_id])))
        |> Enum.reduce(0, &(&2 + &1.value))

      aged / total
    end
  end

  @doc """
  The lineup to measure a team's aging on, and its source id: projections
  when the team was ranked on them, else KeepTradeCut.
  """
  def aging_lineup(team) do
    cond do
      lineup = team.lineups[:proj] -> {lineup, :proj}
      lineup = team.lineups[:ktc] -> {lineup, :ktc}
      true -> {nil, nil}
    end
  end

  @doc """
  Whether a team is an aging contender: strong now (Contender or All-in) with
  at least `aging_share/0` of its lineup (see `aging_lineup/1`) past the cliff.
  Nil for a team that is not contending, where the question does not arise.
  """
  def aging?(tier, share) when tier in ["contender", "all-in"],
    do: share != nil and share >= aging_share()

  def aging?(_tier, _share), do: nil
end
