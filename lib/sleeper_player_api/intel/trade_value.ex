defmodule SleeperPlayerApi.Intel.TradeValue do
  @moduledoc """
  What a package of assets is actually worth, as against the sum of its parts.

  **Summing values is the single biggest way a trade calculator lies.** Eight
  fourth-rounders add up to more than a stud and are not worth a stud: roster
  spots are finite, only so many pieces can start, and the eighth-best asset
  in a package is not doing the work its raw value claims. KeepTradeCut solves
  this in its own calculator, and the shape of the solution — published in
  their client-side JS — is the one modelled here.

  Two effects, and they compound:

    1. **Each piece is discounted by how small it is relative to the best
       asset in the trade.** A sixth power, so it falls away fast: a piece as
       good as the best asset keeps most of its weight, one at half its value
       keeps almost none beyond the floor.
    2. **Each additional piece below half the best asset is discounted
       again**, 15% per piece, floored at 60%. Depth is penalised for being
       depth, not only for being small.

  Every piece keeps a floor of 10% of its raw value — a bench asset is worth
  something, just nowhere near its sticker price.

  `B` is the best asset across **both** sides, not per side. That is what
  makes the comparison symmetric: if it were per-side, a package of eight
  1500s would measure itself against its own best 1500 and look concentrated
  rather than thin.

  **This is a model of their mechanism, not a port of their code, and it is
  not authoritative.** Verify against the live calculator before trusting a
  close call — `parameters/0` exists so the constants can be tuned against
  observed output rather than being spread through the arithmetic.
  """

  # Named so they can be read, cited and re-fitted. Fitted to reproduce the
  # published behaviour; see the moduledoc on verifying against live output.
  @scale_exponent 1.3
  @scale_weight 0.05
  @dominance_exponent 6
  @dominance_weight 0.05
  @dominance_slack 1.05
  @floor 0.10
  @depth_step 0.15
  @depth_floor 0.6
  @depth_threshold 0.5

  # The global normaliser: the most valuable asset on the board, plus a little
  # headroom so the very top piece is not exactly 1.0.
  @top_headroom 80

  @doc "The constants, exposed so a re-fit against live output is a data change."
  def parameters do
    %{
      scale_exponent: @scale_exponent,
      scale_weight: @scale_weight,
      dominance_exponent: @dominance_exponent,
      dominance_weight: @dominance_weight,
      dominance_slack: @dominance_slack,
      floor: @floor,
      depth_step: @depth_step,
      depth_floor: @depth_floor,
      depth_threshold: @depth_threshold,
      top_headroom: @top_headroom
    }
  end

  @doc """
  Evaluates a two-sided trade.

  `side_one` and `side_two` are lists of raw asset values — players, picks, or
  both; nothing here cares which, which is why pick values had to exist first.
  `top_value` is the most valuable asset on the whole board (the #1 player's
  value), which sets the global scale.

  Returns raw and adjusted totals per side, the per-piece breakdown, and which
  side comes out ahead *after* adjustment — which is frequently not the side
  the raw sums favour.

  An empty side is legal and worth zero: a trade under consideration is often
  half-built.
  """
  @spec evaluate([number], [number], number) :: map
  def evaluate(side_one, side_two, top_value) do
    best = Enum.max(side_one ++ side_two, fn -> 0 end)

    one = adjust_side(side_one, best, top_value)
    two = adjust_side(side_two, best, top_value)

    %{
      one: one,
      two: two,
      best_asset: best,
      # Positive means side one is giving up more value than it receives, in
      # adjusted terms. Stated as a signed gap rather than a winner, because
      # "who wins" depends on which side you are.
      adjusted_gap: one.adjusted - two.adjusted,
      raw_gap: one.raw - two.raw
    }
  end

  @doc """
  One side's raw total, adjusted total, and per-piece breakdown.

  Pieces are processed best-first, because the depth penalty counts *how
  many* small pieces precede this one. Processing in arrival order would make
  the same package price differently depending on how it was typed in.
  """
  @spec adjust_side([number], number, number) :: map
  def adjust_side(values, best, top_value) do
    scale = normaliser(top_value)

    {pieces, _depth} =
      values
      |> Enum.sort(:desc)
      |> Enum.map_reduce(0, fn value, depth ->
        depth = if small?(value, best), do: depth + 1, else: depth
        adjusted = piece_value(value, best, scale, depth)

        {%{raw: value, adjusted: adjusted, depth_index: depth, small: small?(value, best)}, depth}
      end)

    %{
      raw: Enum.sum(values),
      adjusted: pieces |> Enum.map(& &1.adjusted) |> Enum.sum(),
      pieces: pieces
    }
  end

  @doc """
  One asset's adjusted contribution.

  `depth` is how many pieces on this side — including this one — are below
  the small-asset threshold. Zero means no depth penalty applies.
  """
  @spec piece_value(number, number, number, non_neg_integer) :: float
  def piece_value(value, best, scale, depth) do
    dominance = safe_ratio(value, @dominance_slack * best)

    multiplier =
      @scale_weight * :math.pow(safe_ratio(value, scale), @scale_exponent) +
        @dominance_weight * :math.pow(dominance, @dominance_exponent) +
        @floor

    value * multiplier * depth_penalty(depth)
  end

  defp depth_penalty(depth) when depth > 0, do: max(@depth_floor, 1 - @depth_step * depth)
  defp depth_penalty(_), do: 1.0

  defp small?(value, best), do: best > 0 and value < @depth_threshold * best

  defp normaliser(top_value), do: top_value + @top_headroom

  # A zero or negative denominator means there is no board to scale against —
  # a contrived input rather than a real one, and returning 0 keeps it from
  # becoming an arithmetic error deep inside a trade evaluation.
  defp safe_ratio(_value, denominator) when denominator <= 0, do: 0.0
  defp safe_ratio(value, denominator), do: value / denominator
end
