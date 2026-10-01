defmodule SleeperPlayerApi.Intel.MarketSettingsTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApi.Intel.MarketSettings

  describe "parse/1" do
    test "falls back to the stored slice when nothing is asked for" do
      assert {:ok, settings} = MarketSettings.parse(%{})
      assert settings == MarketSettings.default()
    end

    test "reads every field" do
      assert {:ok, settings} =
               MarketSettings.parse(%{
                 "dynasty" => "false",
                 "num_qbs" => "1",
                 "num_teams" => "10",
                 "ppr" => "0.5"
               })

      assert settings == %{dynasty: false, num_qbs: 1, num_teams: 10, ppr: 0.5}
    end

    # A caller that knows only its league size should not have to look up a
    # PPR to say so.
    test "falls back field by field, not all or nothing" do
      assert {:ok, settings} = MarketSettings.parse(%{"num_teams" => "10"})
      assert settings == %{MarketSettings.default() | num_teams: 10}
    end

    # Substituting the default for a bad value answers a question nobody
    # asked, in a feature whose whole point is knowing which question was.
    test "rejects a value it cannot read rather than substituting the default" do
      assert {:error, {:invalid_param, "num_teams", "twelve"}} =
               MarketSettings.parse(%{"num_teams" => "twelve"})
    end

    test "rejects a trailing-garbage number" do
      assert {:error, {:invalid_param, "num_qbs", "2x"}} =
               MarketSettings.parse(%{"num_qbs" => "2x"})
    end

    test "rejects a dynasty flag that is not a boolean" do
      assert {:error, {:invalid_param, "dynasty", "yes"}} =
               MarketSettings.parse(%{"dynasty" => "yes"})
    end

    # Bounds exist so this API cannot be used to make arbitrary outbound
    # requests, not to second-guess which leagues exist.
    test "rejects sizes outside the bounds" do
      assert {:error, {:param_out_of_range, "num_teams", "0", 2, 32}} =
               MarketSettings.parse(%{"num_teams" => "0"})

      assert {:error, {:param_out_of_range, "num_teams", "99", 2, 32}} =
               MarketSettings.parse(%{"num_teams" => "99"})

      assert {:error, {:param_out_of_range, "ppr", "-1", 0, 3}} =
               MarketSettings.parse(%{"ppr" => "-1"})
    end

    # 999 is a perfectly good integer; saying it is not one is a false
    # statement, and this feature's standing failure is the sentence rather
    # than the number.
    test "tells an unreadable value apart from an out-of-range one" do
      assert {:error, {:invalid_param, _, _}} = MarketSettings.parse(%{"num_teams" => "twelve"})

      assert {:error, {:param_out_of_range, _, _, _, _}} =
               MarketSettings.parse(%{"num_teams" => "999"})
    end

    test "accepts a whole number for ppr" do
      assert {:ok, %{ppr: 0.0}} = MarketSettings.parse(%{"ppr" => "0"})
    end
  end

  describe "default?/1" do
    test "is true for the stored slice" do
      assert MarketSettings.default?(MarketSettings.default())
    end

    test "is false for anything else" do
      refute MarketSettings.default?(%{MarketSettings.default() | num_qbs: 1})
    end

    # The payoff for clamping: a 12-team full-PPR dynasty league that starts
    # three quarterbacks is asking the stored slice's question, so it is
    # answered from the database with no fetch at all.
    test "is true for a league whose extra quarterbacks the provider ignores" do
      assert MarketSettings.default?(%{MarketSettings.default() | num_qbs: 3})
      assert MarketSettings.default?(%{MarketSettings.default() | num_qbs: 4})
    end
  end

  describe "parse/1 and the clamp" do
    # Only what is *sent* is clamped. "You start four quarterbacks" is true
    # about the league, and the clamp is a fact about the provider.
    test "keeps the caller's own quarterback count in the settings" do
      assert {:ok, %{num_qbs: 4}} = MarketSettings.parse(%{"num_qbs" => "4"})
    end
  end

  describe "to_query/1" do
    test "builds the provider's query string" do
      query = MarketSettings.to_query(%{dynasty: true, num_qbs: 2, num_teams: 12, ppr: 1.0})

      assert URI.decode_query(query) == %{
               "isDynasty" => "true",
               "numQbs" => "2",
               "numTeams" => "12",
               "ppr" => "1"
             }
    end

    # The query string is the cache key, so two callers asking the same
    # question must not produce two entries for one answer.
    test "writes a whole-number ppr the same way however it arrived" do
      {:ok, from_int} = MarketSettings.parse(%{"ppr" => "1"})
      {:ok, from_float} = MarketSettings.parse(%{"ppr" => "1.0"})

      assert MarketSettings.to_query(from_int) == MarketSettings.to_query(from_float)
    end

    # FantasyCalc prices one quarterback or more-than-one and nothing beyond:
    # measured against the live API, numQbs of 2, 3 and 4 return identical
    # values. Asking for 4 spends a second request on somebody else's free API
    # for an answer already held under a different key.
    test "asks for no more quarterbacks than the provider prices" do
      four = MarketSettings.to_query(%{dynasty: true, num_qbs: 4, num_teams: 12, ppr: 1.0})
      two = MarketSettings.to_query(%{dynasty: true, num_qbs: 2, num_teams: 12, ppr: 1.0})

      assert URI.decode_query(four)["numQbs"] == "2"
      assert four == two
    end

    test "leaves a single-quarterback league alone" do
      query = MarketSettings.to_query(%{dynasty: true, num_qbs: 1, num_teams: 12, ppr: 1.0})

      assert URI.decode_query(query)["numQbs"] == "1"
    end

    test "keeps a fractional ppr" do
      assert MarketSettings.to_query(%{dynasty: true, num_qbs: 1, num_teams: 10, ppr: 0.5})
             |> URI.decode_query()
             |> Map.get("ppr") == "0.5"
    end
  end

  describe "from_league/1" do
    test "counts every quarterback a lineup can hold, QB slots plus a superflex" do
      # 4 QB Madness's shape: three QB slots and a superflex. Stopping at the
      # superflex would report two.
      league = %{"roster_positions" => ["QB", "QB", "QB", "SUPER_FLEX", "RB", "BN"]}

      assert MarketSettings.from_league(league).num_qbs == 4
    end

    test "reads a true two-QB league as superflex for pricing, with no superflex slot" do
      settings = MarketSettings.from_league(%{"roster_positions" => ["QB", "QB", "RB", "WR"]})

      assert settings.num_qbs == 2
      assert MarketSettings.superflex?(settings)
    end

    test "a one-QB league is not superflex" do
      settings = MarketSettings.from_league(%{"roster_positions" => ["QB", "RB", "FLEX", "BN"]})

      refute MarketSettings.superflex?(settings)
    end

    test "only Sleeper type 2 is dynasty; keeper and redraft are not" do
      for {type, dynasty} <- [{0, false}, {1, false}, {2, true}, {3, false}] do
        assert MarketSettings.from_league(%{"settings" => %{"type" => type}}).dynasty == dynasty
      end
    end

    test "standard scoring is a real answer, not an absence" do
      assert MarketSettings.from_league(%{"scoring_settings" => %{"rec" => 0}}).ppr == 0.0
    end

    test "falls back to the stored slice field by field" do
      assert MarketSettings.from_league(%{"total_rosters" => 10}) ==
               %{MarketSettings.default() | num_teams: 10}
    end
  end

  describe "ktc_tep_level/1" do
    defp league(te_slots, bonus, rec \\ 1.0) do
      %{
        "roster_positions" => List.duplicate("TE", te_slots) ++ ["QB", "RB", "FLEX"],
        "scoring_settings" => %{"rec" => rec, "bonus_rec_te" => bonus}
      }
    end

    test "no TE premium for one TE and no bonus" do
      assert MarketSettings.ktc_tep_level(league(1, nil)) == nil
      assert MarketSettings.ktc_tep_level(league(1, 0)) == nil
    end

    test "TE+ for a mild bonus, up to double the receivers' PPR" do
      # League of Boredom (+0.5), 4 QB Madness (+0.75), $uperFlexual (+1.0).
      for bonus <- [0.5, 0.75, 1.0],
          do: assert(MarketSettings.ktc_tep_level(league(1, bonus)) == "tep")
    end

    test "TE++ for more than double, or for two TE slots" do
      assert MarketSettings.ktc_tep_level(league(1, 1.5)) == "tepp"
      assert MarketSettings.ktc_tep_level(league(2, 0)) == "tepp"
      # Half PPR with a full point for tight ends is triple.
      assert MarketSettings.ktc_tep_level(league(1, 1.0, 0.5)) == "tepp"
    end

    test "TE+++ for two TE slots and a bonus" do
      assert MarketSettings.ktc_tep_level(league(2, 0.5)) == "teppp"
    end

    test "a flex is not a TE slot" do
      assert MarketSettings.ktc_tep_level(%{"roster_positions" => ["TE", "FLEX", "FLEX"]}) == nil
    end
  end
end
