defmodule SleeperPlayerApi.SleeperFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `SleeperPlayerApi.Sleeper` context.
  """

  @doc """
  Generate a unique player player_id.
  """
  def unique_player_player_id, do: "some player_id#{System.unique_integer([:positive])}"

  def unique_player_id, do: System.unique_integer([:positive])

  @doc """
  Generate a player.
  """
  def player_fixture(attrs \\ %{}) do
    Map.put(attrs, :id, unique_player_id())
    {:ok, player} =
      attrs
      |> Enum.into(%{
        id: unique_player_id(),
        active: true,
        age: 42,
        first_name: "some first_name",
        full_name: "some full_name",
        last_name: "some last_name",
        player_id: unique_player_player_id(),
        player_json: "some player_json",
        position: "some position",
        search_first_name: "some search_first_name",
        search_full_name: "some search_full_name",
        search_last_name: "some search_last_name",
        search_rank: 42,
        years_exp: 42,
      })
      |> SleeperPlayerApi.Sleeper.create_player()

    player
  end

  @doc """
  Generate a unique status.
  """
  def unique_status, do: "some status#{System.unique_integer([:positive])}"

  @doc """
  Generate a status.
  """
  def status_fixture(attrs \\ %{}) do
    {:ok, status} =
      attrs
      |> Enum.into(%{
        status: unique_status()
      })
      |> SleeperPlayerApi.Sleeper.create_status()

    status
  end

  @doc """
  Generate a unique team abbreviation.
  """
  def unique_team_abbreviation, do: "some team#{System.unique_integer([:positive])}"

  @doc """
  Generate a team.
  """
  def team_fixture(attrs \\ %{}) do
    {:ok, team} =
      attrs
      |> Enum.into(%{
        abbreviation: unique_team_abbreviation()
      })
      |> SleeperPlayerApi.Sleeper.create_team()

    team
  end

  @doc """
  Generate a unique position abbreviation.
  """
  def unique_position_abbreviation, do: "some abbreviation#{System.unique_integer([:positive])}"

  @doc """
  Generate a position.
  """
  def position_fixture(attrs \\ %{}) do
    {:ok, position} =
      attrs
      |> Enum.into(%{
        abbreviation: unique_position_abbreviation()
      })
      |> SleeperPlayerApi.Sleeper.create_position()

    position
  end
end
