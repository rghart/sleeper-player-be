defmodule SleeperPlayerApiWeb.AdpJSON do
  @moduledoc "Renders the market ADP endpoints, camelCase like the rest of this API."

  alias SleeperPlayerApi.Market.{Adp, Format}

  def index(%{counts: counts, since: since}) do
    target =
      :sleeper_player_api
      |> Application.get_env(SleeperPlayerApi.Tasks.CrawlMarketDrafts, [])
      |> Keyword.get(:target_per_bucket, 150)

    %{
      since: since,
      target: target,
      buckets:
        Enum.map(Format.buckets(), fn bucket ->
          %{bucket: Format.bucket_key(bucket), drafts: counts[bucket]}
        end)
    }
  end

  def show(assigns) do
    %{
      bucket: Format.bucket_key(assigns.bucket),
      since: assigns.since,
      drafts: assigns.drafts,
      # Drafts in the bucket left out as not what they claim to be (a
      # "rookie" draft that was mostly veterans).
      excludedDrafts: assigns.excluded_drafts,
      # Players with an ADP in all, before `limit` cut the list.
      players: assigns.total_players,
      minDrafts: Adp.min_drafts(),
      adp:
        Enum.map(assigns.players, fn p ->
          %{
            playerId: p.player_id,
            adp: p.adp,
            median: p.median,
            stdev: p.stdev,
            min: p.min,
            max: p.max,
            n: p.n,
            rate: p.rate,
            sleeperAdp: assigns.sleeper[p.player_id]
          }
        end),
      sleeper: %{
        column: assigns.column.column,
        notes: assigns.column.notes,
        comparison: comparison(assigns.comparison)
      }
    }
  end

  defp comparison(nil), do: nil

  defp comparison(c) do
    %{
      shared: c.shared,
      spearman: c.spearman,
      meanAbsRankDiff: c.mean_abs_rank_diff,
      disagreements:
        Enum.map(c.disagreements, fn d ->
          %{playerId: d.player_id, ourRank: d.our_rank, sleeperRank: d.sleeper_rank, diff: d.diff}
        end)
    }
  end
end
