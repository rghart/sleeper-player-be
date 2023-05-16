defmodule SleeperPlayerApi.SleeperFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `SleeperPlayerApi.Sleeper` context.
  """

  @doc """
  Generate a player.
  """
  def player_fixture(attrs \\ %{}) do
    {:ok, player} =
      attrs
      |> Enum.into(%{
        player_data: %{}
      })
      |> SleeperPlayerApi.Sleeper.create_player()

    player
  end

  @doc """
  Generate a unique player player_id.
  """
  def unique_player_player_id, do: "some player_id#{System.unique_integer([:positive])}"

  @doc """
  Generate a player.
  """
  def player_fixture(attrs \\ %{}) do
    {:ok, player} =
      attrs
      |> Enum.into(%{
        active: true,
        age: 42,
        fantasy_positions: ["option1", "option2"],
        first_name: "some first_name",
        full_name: "some full_name",
        last_name: "some last_name",
        player_data: %{},
        player_id: unique_player_player_id(),
        position: "some position",
        search_first_name: "some search_first_name",
        search_full_name: "some search_full_name",
        search_last_name: "some search_last_name",
        search_rank: 42,
        status: "some status",
        years_exp: 42
      })
      |> SleeperPlayerApi.Sleeper.create_player()

    player
  end
end
