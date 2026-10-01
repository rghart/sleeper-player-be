defmodule SleeperPlayerApi.Market.Adp do
  @moduledoc """
  Average draft position from real drafts, and how it compares with
  Sleeper's own ADP (docs/dynasty-engine.md, M3). Pure: takes the picks of
  one format bucket's drafts, and Sleeper's ADP column, and returns numbers.

  **ADP here is the mean overall pick among the drafts a player went in**,
  reported with what makes it honest to read:

    * `n` and `rate`: how many of the bucket's drafts took him, and what
      share. A player taken in 20% of rookie drafts has an ADP drawn from the
      drafts that wanted him, so it reads earlier than his market really is;
      `rate` is how a caller can tell.
    * `median`, `stdev`, `min`, `max`: one reach does not move a median, and
      the spread says how settled the market is on him.

  A player taken in fewer than `min_drafts` drafts (config) is left out: an
  average over two picks is an anecdote.

  **The comparison** ranks the players both lists cover and reports
  Spearman's rank correlation, the mean rank difference, and the biggest
  disagreements. That is the decision gate the plan asks for: whether to keep
  Sleeper's ADP, replace it with this, or blend the two, decided with the
  numbers in hand rather than by trust.
  """

  defp config(key, default) do
    :sleeper_player_api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc "The fewest drafts a player must go in to get an ADP, from config."
  def min_drafts, do: config(:min_drafts, 5)

  @doc "The least share of a rookie draft's picks that must be rookies, from config."
  def rookie_min_share, do: config(:rookie_min_share, 0.75)

  # Positions whose draft spot says more about a league's lineup than about
  # the market: a league that starts a kicker drafts one, one that does not
  # never will. They keep their ADP, where `rate` shows how few drafts take
  # them, but are left out of the comparison with Sleeper.
  @league_dependent ["K", "DEF"]

  @doc """
  Drops "rookie" drafts that are not rookie drafts, as `{kept, dropped}`.

  Sleeper's `player_type` marks a draft rookies-only, but some leagues run a
  veteran supplemental draft under that flag. Found on the first production
  corpus: one 10-round "rookie" draft took Pat Freiermuth and a 14-year
  kicker ahead of the top rookie, and that one draft moved every top
  rookie's mean pick by about half a place. A draft counts when at least
  `rookie_min_share/0` of its picks were rookies in the draft's season.

  `years_exp` is `%{player_id => years_exp}` as of `current_season`; a rookie
  of season S has `current_season - S` years. A pick whose player is not in
  the map is not counted either way.
  """
  def rookie_drafts_only(drafts, years_exp, current_season) do
    min_share = rookie_min_share()

    Enum.split_with(drafts, fn draft ->
      known = rookie_flags(draft, years_exp, current_season)
      known == [] or Enum.count(known, & &1) / length(known) >= min_share
    end)
  end

  # Whether each pick whose player is known was a rookie in the draft's
  # season. Empty, and so kept, when the season cannot be read.
  defp rookie_flags(draft, years_exp, current_season) do
    case to_season(draft[:season]) do
      nil ->
        []

      season ->
        rookie_exp = current_season - season

        Enum.flat_map(draft.picks, fn pick ->
          case years_exp[pick.player_id] do
            nil -> []
            exp -> [exp == rookie_exp]
          end
        end)
    end
  end

  defp to_season(season) when is_integer(season), do: season

  defp to_season(season) when is_binary(season) do
    case Integer.parse(season) do
      {year, ""} -> year
      _ -> nil
    end
  end

  defp to_season(_), do: nil

  @doc """
  `players` without the league-dependent positions (K, DEF), for comparing
  with Sleeper. `positions` is `%{player_id => position}`.
  """
  def comparable(players, positions),
    do: Enum.reject(players, &(positions[&1.player_id] in @league_dependent))

  @doc """
  ADP for one bucket. `drafts` is a list of `%{id, picks: [%{pick_no,
  player_id}]}`. Returns players sorted by ADP, earliest first, each
  `%{player_id, adp, median, stdev, min, max, n, rate}`.
  """
  def compute(drafts) do
    total = length(drafts)
    min = min_drafts()

    drafts
    |> Enum.flat_map(fn draft ->
      # One pick per player per draft: a duplicate in a payload would count
      # him twice.
      draft.picks |> Enum.uniq_by(& &1.player_id) |> Enum.map(&{&1.player_id, &1.pick_no})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_player, picks} -> length(picks) >= min end)
    |> Enum.map(fn {player, picks} -> summarize(player, picks, total) end)
    |> Enum.sort_by(&{&1.adp, &1.player_id})
  end

  defp summarize(player, picks, total) do
    n = length(picks)
    mean = Enum.sum(picks) / n
    variance = Enum.reduce(picks, 0, &(&2 + (&1 - mean) ** 2)) / n

    %{
      player_id: player,
      adp: mean,
      median: median(picks),
      stdev: :math.sqrt(variance),
      min: Enum.min(picks),
      max: Enum.max(picks),
      n: n,
      rate: n / total
    }
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid) * 1.0,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  @doc """
  How this ADP compares with Sleeper's, over the players both cover.

  `ours` is `compute/1`'s output; `sleeper` is `%{player_id => adp}`.
  Returns nil when fewer than three players are shared (no correlation to
  speak of), else `%{shared, spearman, mean_abs_rank_diff, disagreements}`,
  where `disagreements` are the `limit` shared players whose ranks differ
  most: `%{player_id, our_rank, sleeper_rank, diff}`, with `diff` positive
  when the market here takes him later than Sleeper says.
  """
  def compare(ours, sleeper, limit \\ 10) do
    shared = Enum.filter(ours, &is_number(sleeper[&1.player_id]))

    if length(shared) < 3 do
      nil
    else
      ids = Enum.map(shared, & &1.player_id)
      our_ranks = ranks(Map.new(shared, &{&1.player_id, &1.adp}))
      their_ranks = ranks(Map.new(ids, &{&1, sleeper[&1]}))

      diffs =
        Enum.map(ids, fn id ->
          %{
            player_id: id,
            our_rank: our_ranks[id],
            sleeper_rank: their_ranks[id],
            diff: our_ranks[id] - their_ranks[id]
          }
        end)

      %{
        shared: length(ids),
        spearman: pearson(Enum.map(ids, &our_ranks[&1]), Enum.map(ids, &their_ranks[&1])),
        mean_abs_rank_diff: Enum.reduce(diffs, 0, &(&2 + abs(&1.diff))) / length(diffs),
        disagreements: diffs |> Enum.sort_by(&{-abs(&1.diff), &1.our_rank}) |> Enum.take(limit)
      }
    end
  end

  # 1-based ranks by value, ties sharing their average rank, as Spearman's
  # coefficient requires.
  defp ranks(values_by_id) do
    values_by_id
    |> Enum.sort_by(fn {id, v} -> {v, id} end)
    |> Enum.with_index(1)
    |> Enum.chunk_by(fn {{_id, v}, _rank} -> v end)
    |> Enum.flat_map(fn tied ->
      average = Enum.sum(Enum.map(tied, &elem(&1, 1))) / length(tied)
      Enum.map(tied, fn {{id, _v}, _rank} -> {id, average} end)
    end)
    |> Map.new()
  end

  defp pearson(xs, ys) do
    n = length(xs)
    mx = Enum.sum(xs) / n
    my = Enum.sum(ys) / n
    cov = Enum.zip(xs, ys) |> Enum.reduce(0, fn {x, y}, acc -> acc + (x - mx) * (y - my) end)
    sx = :math.sqrt(Enum.reduce(xs, 0, &(&2 + (&1 - mx) ** 2)))
    sy = :math.sqrt(Enum.reduce(ys, 0, &(&2 + (&1 - my) ** 2)))
    if sx == 0 or sy == 0, do: nil, else: cov / (sx * sy)
  end
end
