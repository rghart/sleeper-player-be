defmodule SleeperPlayerApi.Intel.MarketSettings do
  @moduledoc """
  The league shape a set of market values is *of*.

  Values are not one list. FantasyCalc prices a player against a format, and
  the difference is not a rounding: in superflex their top player is a
  quarterback and in single-QB it is a running back. A caller handed the
  wrong slice is not looking at slightly-off numbers, it is looking at a
  different game.

  The nightly refresh stores exactly one slice — the default below — because
  the availability model in `SleeperPlayerApi.Intel` is calibrated against
  it. That default must not change without recalibrating; everything else is
  fetched on request.
  """

  @type t :: %{dynasty: boolean, num_qbs: pos_integer, num_teams: pos_integer, ppr: float}

  # The stored slice. `RefreshPlayerValues` writes this one nightly and the
  # estimator is calibrated against it — see plan §2.
  @default %{dynasty: true, num_qbs: 2, num_teams: 12, ppr: 1.0}

  # Bounds, not a supported-values list. FantasyCalc answers 200 for anything
  # asked of it (an 11-team league, `numQbs=3`), so these exist to stop this
  # API being used to make arbitrary outbound requests, not to second-guess
  # what leagues exist. A 32-team league is absurd and also harmless.
  @max_teams 32
  @max_qbs 4

  # The most quarterbacks FantasyCalc prices differently. Not a bound on what
  # a caller may ask - `@max_qbs` is that - but the point past which asking
  # for more returns the same answer. Must stay above its uses: a module
  # attribute read before it is set is `nil`, and `min(4, nil)` is 4 in Erlang
  # term order, so the clamp would silently do nothing.
  @priced_qbs 2

  @doc "The slice the nightly refresh stores, and the default for a request."
  @spec default() :: t
  def default, do: @default

  @doc """
  Whether these settings are answerable from the stored slice without a fetch.

  Compares what the provider would actually be asked, not what the caller
  said - so a 12-team full-PPR dynasty league that starts three quarterbacks
  is the stored slice, because `effective/1` reads it as two and the values
  are identical either way.
  """
  @spec default?(t) :: boolean
  def default?(settings), do: effective(settings) == @default

  # The settings as the provider will actually read them.
  #
  # FantasyCalc prices one quarterback or more-than-one, and nothing beyond:
  # measured against the live API with everything else equal, `numQbs` of 2, 3
  # and 4 return byte-identical values. So a league that starts four is asking
  # the same question as one that starts two, and asking it under a different
  # name buys nothing and costs a second request to somebody else's free API.
  #
  # Only what is *sent* is clamped. The settings a caller gets back still
  # describe their league, because "you start four quarterbacks" is true and
  # this is a fact about the provider rather than about them.
  defp effective(settings), do: %{settings | num_qbs: min(settings.num_qbs, @priced_qbs)}

  @doc """
  Request params as settings, falling back to the stored slice field by field.

  Field by field rather than all-or-nothing: a caller that knows only its
  league size should be able to say so without also having to state a PPR it
  has not looked up.

  Returns `{:error, {:invalid_param, key, value}}` for something unreadable
  and `{:error, {:param_out_of_range, key, value, min, max}}` for a number
  that read fine and is not allowed — the two are told apart for the same
  reason `:pick_out_of_range` is separate from `:invalid_param` elsewhere in
  this API: "num_teams must be an integer, got 999" is a false statement
  about a perfectly good integer.

  Either way it is an error rather than a silent fallback. Substituting the
  default for a bad value answers a question nobody asked, in a feature whose
  whole point is knowing which question was.
  """
  @spec parse(map) ::
          {:ok, t}
          | {:error, {:invalid_param, String.t(), term}}
          | {:error, {:param_out_of_range, String.t(), term, number, number}}
  def parse(params) do
    with {:ok, dynasty} <- boolean(params, "dynasty", @default.dynasty),
         {:ok, num_qbs} <- integer(params, "num_qbs", @default.num_qbs, 1, @max_qbs),
         {:ok, num_teams} <- integer(params, "num_teams", @default.num_teams, 2, @max_teams),
         {:ok, ppr} <- number(params, "ppr", @default.ppr, 0, 3) do
      {:ok, %{dynasty: dynasty, num_qbs: num_qbs, num_teams: num_teams, ppr: ppr}}
    end
  end

  @doc """
  These settings as FantasyCalc's query string.

  Clamped to what the provider actually prices - see `effective/1`. This
  string is also the cache key, so the clamp is what stops a three-QB and a
  four-QB league being two cached copies of one answer.
  """
  @spec to_query(t) :: String.t()
  def to_query(settings) do
    %{dynasty: dynasty, num_qbs: num_qbs, num_teams: num_teams, ppr: ppr} = effective(settings)

    URI.encode_query(%{
      "isDynasty" => to_string(dynasty),
      "numQbs" => num_qbs,
      "numTeams" => num_teams,
      "ppr" => format_ppr(ppr)
    })
  end

  # 1.0 as "1", 0.5 as "0.5". FantasyCalc takes either, but the query string
  # is the cache key, so `ppr=1` and `ppr=1.0` arriving from two callers must
  # not become two entries for one answer.
  defp format_ppr(ppr) do
    if ppr == trunc(ppr), do: trunc(ppr), else: ppr
  end

  defp boolean(params, key, fallback) do
    case params[key] do
      nil -> {:ok, fallback}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      other -> {:error, {:invalid_param, key, other}}
    end
  end

  defp integer(params, key, fallback, min, max) do
    case params[key] do
      nil ->
        {:ok, fallback}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= min and int <= max -> {:ok, int}
          {_int, ""} -> {:error, {:param_out_of_range, key, value, min, max}}
          _ -> {:error, {:invalid_param, key, value}}
        end

      other ->
        {:error, {:invalid_param, key, other}}
    end
  end

  defp number(params, key, fallback, min, max) do
    case params[key] do
      nil ->
        {:ok, fallback}

      value when is_binary(value) ->
        case Float.parse(value) do
          {float, ""} when float >= min and float <= max -> {:ok, float}
          {_float, ""} -> {:error, {:param_out_of_range, key, value, min, max}}
          _ -> {:error, {:invalid_param, key, value}}
        end

      other ->
        {:error, {:invalid_param, key, other}}
    end
  end
end
