defmodule SleeperPlayerApi.Tasks.GetSleeperPlayerDataTest do
  use SleeperPlayerApi.DataCase, async: true

  alias SleeperPlayerApi.Repo
  alias SleeperPlayerApi.Sleeper.Player
  alias SleeperPlayerApi.Tasks.GetSleeperPlayerData

  # A trimmed slice of a real `/players/nfl` entry (2026-08-15), keeping the
  # injury fields exactly as Sleeper spells them. They have been in this
  # payload all along, landing in `player_json` and read by nothing — see the
  # migration that added the columns.
  defp payload(attrs \\ %{}) do
    Map.merge(
      %{
        "player_id" => "6794",
        "first_name" => "Malik",
        "last_name" => "Nabers",
        "full_name" => "Malik Nabers",
        "search_first_name" => "malik",
        "search_last_name" => "nabers",
        "search_full_name" => "maliknabers",
        "active" => true,
        "age" => 23,
        "years_exp" => 2,
        "injury_status" => "Questionable",
        "injury_body_part" => "Knee - ACL"
      },
      attrs
    )
  end

  test "the nightly dump extracts the injury fields it used to bury in player_json" do
    GetSleeperPlayerData.add_or_update_player_in_repo(payload())

    assert %Player{injury_status: "Questionable", injury_body_part: "Knee - ACL"} =
             Repo.get(Player, 6794)
  end

  test "a player who gets hurt between runs stops reading healthy" do
    GetSleeperPlayerData.add_or_update_player_in_repo(payload(%{"injury_status" => nil}))
    assert %Player{injury_status: nil} = Repo.get(Player, 6794)

    GetSleeperPlayerData.add_or_update_player_in_repo(payload())
    assert %Player{injury_status: "Questionable"} = Repo.get(Player, 6794)
  end

  # The direction that actually goes wrong. Sleeper sends the key with an
  # explicit `null` rather than omitting it when a player is healthy —
  # measured 2026-08-15 over 2,886 uninjured actives, key present on all of
  # them, absent on none — which is what lets `cast/3` clear the column. Were
  # it omitted instead, cast would skip it and last week's injury would stay
  # on screen forever, so this pins the payload shape as much as the code.
  test "a player who recovers stops reading hurt" do
    GetSleeperPlayerData.add_or_update_player_in_repo(payload())
    assert %Player{injury_status: "Questionable"} = Repo.get(Player, 6794)

    GetSleeperPlayerData.add_or_update_player_in_repo(
      payload(%{"injury_status" => nil, "injury_body_part" => nil})
    )

    assert %Player{injury_status: nil, injury_body_part: nil} = Repo.get(Player, 6794)
  end
end
