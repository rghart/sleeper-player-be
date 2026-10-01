defmodule SleeperPlayerApiWeb.AdpController do
  use SleeperPlayerApiWeb, :controller

  alias SleeperPlayerApi.{Intel, Market}
  alias SleeperPlayerApi.Market.{Adp, Format}

  action_fallback SleeperPlayerApiWeb.FallbackController

  @default_limit 200
  @max_limit 1000

  @doc """
  `GET /api/v1/adp` — how far the market corpus has got: complete drafts per
  format bucket in the window, against the target the crawler fills to.
  """
  def index(conn, _params) do
    since = Format.window_start()
    render(conn, :index, counts: Market.bucket_counts(since), since: since)
  end

  @doc """
  `GET /api/v1/adp/:bucket?limit=` — ADP from real drafts for one format
  bucket (`startup-sf-tep`, `rookie-1qb-no_tep`, ...), earliest first, with
  Sleeper's ADP beside each player and the comparison between the two
  (`Market.Adp`). docs/dynasty-engine.md, M3.
  """
  def show(conn, %{"bucket" => key} = params) do
    with {:ok, bucket} <- parse_bucket(key),
         {:ok, limit} <- parse_limit(params["limit"]) do
      since = Format.window_start()
      drafts = Market.bucket_drafts(bucket, since)
      players = Adp.compute(drafts)
      column = Format.sleeper_column(bucket)
      sleeper = sleeper_adp(column.column)

      render(conn, :show,
        bucket: bucket,
        since: since,
        drafts: length(drafts),
        players: Enum.take(players, limit),
        total_players: length(players),
        sleeper: sleeper,
        column: column,
        comparison: Adp.compare(players, sleeper)
      )
    end
  end

  # Sleeper's ADP column from the latest stored season's projections, as
  # `%{player_id => adp}`. Sleeper writes 999 for "no ADP".
  defp sleeper_adp(column) do
    case Intel.latest_projections_season() do
      nil ->
        %{}

      season ->
        season
        |> Intel.projections()
        |> Enum.reduce(%{}, fn row, acc ->
          case row["stats"][column] do
            adp when is_number(adp) and adp < 999 -> Map.put(acc, row["player_id"], adp)
            _ -> acc
          end
        end)
    end
  end

  defp parse_bucket(key) do
    case Format.parse_key(key) do
      {:ok, bucket} -> {:ok, bucket}
      :error -> {:error, :not_found}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 and n <= @max_limit -> {:ok, n}
      {n, ""} -> {:error, {:param_out_of_range, :limit, n, 1, @max_limit}}
      _ -> {:error, {:invalid_param, :limit, raw}}
    end
  end
end
