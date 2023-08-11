defmodule SleeperPlayerApi.Sleeper do
  @moduledoc """
  The Sleeper context.
  """

  import Ecto.Query, warn: false
  alias SleeperPlayerApi.Repo

  alias SleeperPlayerApi.Sleeper.{Player, Position, Team, Status}

  @player_preloads [:status, :team, :position, :fantasy_positions]

  @doc """
  Returns the list of players.

  ## Examples

      iex> list_players()
      [%Player{}, ...]

  """
  def list_players do
    Repo.all(Player)
    |> Repo.preload(@player_preloads)
  end

  @doc """
  Returns the list of active players.

  ## Examples

      iex> list_active_players()
      [%Player{active: true}, ...]

  """
  def list_active_players do
    Repo.all(from Player, where: [active: true], preload: ^@player_preloads)
  end

  @doc """
  Gets a single player.

  Raises `Ecto.NoResultsError` if the Player does not exist.

  ## Examples

      iex> get_player!(123)
      %Player{}

      iex> get_player!(456)
      ** (Ecto.NoResultsError)

  """
  def get_player!(id) do
    Repo.get!(Player, id)
    |> Repo.preload(@player_preloads)
  end

  @doc """
  Gets a single player.

  Raises nil if the Player does not exist.

  ## Examples

      iex> get_player(123)
      %Player{}

      iex> get_player(456)
      nil

  """
  def get_player(id) do
    Repo.get(Player, id)
    |> Repo.preload(@player_preloads)
  end

  @doc """
  Creates a player.

  ## Examples

      iex> create_player(%{field: value})
      {:ok, %Player{}}

      iex> create_player(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_player(attrs \\ %{}) do
    %Player{}
    |> change_player(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a player.

  ## Examples

      iex> update_player(player, %{field: new_value})
      {:ok, %Player{}}

      iex> update_player(player, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_player(%Player{} = player, attrs) do
    player
    |> change_player(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a player.

  ## Examples

      iex> delete_player(player)
      {:ok, %Player{}}

      iex> delete_player(player)
      {:error, %Ecto.Changeset{}}

  """
  def delete_player(%Player{} = player) do
    Repo.delete(player)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking player changes.

  ## Examples

      iex> change_player(player)
      %Ecto.Changeset{data: %Player{}}

  """
  def change_player(%Player{} = player, attrs \\ %{}) do
    positions = attrs["fantasy_positions"]
    status = attrs["status"]
    team = attrs["team"]
    position = attrs["position"]

    new_attrs = [
      {status, "status_id", &get_status_by_status/1},
      {team, "team_id", &get_team_by_abbreviation/1},
      {position, "position_id", &get_position_by_abbreviation/1}
    ]

    attrs = Enum.reduce(new_attrs, attrs,
      fn {attr, k, func}, attrs -> if attr, do: Map.put(attrs, k, func.(attr).id), else: attrs end
    )

    player = Repo.preload(player, @player_preloads)
    changes = Player.changeset(player, attrs)

    changes = if positions do
      Ecto.Changeset.put_assoc(changes, :fantasy_positions, list_positions_by_abbreviation(positions))
    else
      changes
    end

    changes
  end

  def list_positions_by_abbreviation(abbr) do
    Repo.all(from pos in Position, where: pos.abbreviation in ^abbr)
  end

  @doc """
  Returns the list of positions.

  ## Examples

      iex> list_positions()
      [%Position{}, ...]

  """
  def list_positions do
    Repo.all(Position)
  end

  @doc """
  Gets a single position by abbreviation.

  Return nil if the Position does not exist.

  ## Examples

      iex> get_position_by_abbreviation("WR")
      %Position{}

  """
  def get_position_by_abbreviation(abbr) do
    Repo.get_by(Position, abbreviation: abbr)
  end

  @doc """
  Creates a position.

  ## Examples

      iex> create_position(%{field: value})
      {:ok, %Position{}}

      iex> create_position(%{field: bad_value})
      {:error, ...}

  """
  def create_position(attrs \\ %{}) do
    %Position{}
    |> Position.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns the list of teams.

  ## Examples

      iex> list_teams()
      [%Team{}, ...]

  """
  def list_teams do
    Repo.all(Team)
  end

  @doc """
  Gets a single team by abbreviation.

  Return nil if the Team does not exist.

  ## Examples

      iex> get_team_by_abbreviation("TEN")
      %Team{}

  """
  def get_team_by_abbreviation(abbr) do
    Repo.get_by(Team, abbreviation: abbr)
  end

  @doc """
  Creates a team.

  ## Examples

      iex> create_team(%{field: value})
      {:ok, %Team{}}

      iex> create_team(%{field: bad_value})
      {:error, ...}

  """
  def create_team(attrs \\ %{}) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns the list of statuses.

  ## Examples

      iex> list_statuses()
      [%Status{}, ...]

  """
  def list_statuses do
    Repo.all(Status)
  end

  @doc """
  Gets a single status by status.

  Return nil if the Status does not exist.

  ## Examples

      iex> get_status_by_status("Injured Reserve")
      %Status{}

  """
  def get_status_by_status(status) do
    Repo.get_by(Status, status: status)
  end

  @doc """
  Creates a status.

  ## Examples

      iex> create_status(%{field: value})
      {:ok, %Status{}}

      iex> create_status(%{field: bad_value})
      {:error, ...}

  """
  def create_status(attrs \\ %{}) do
    %Status{}
    |> Status.changeset(attrs)
    |> Repo.insert()
  end
end
