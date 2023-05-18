defmodule SleeperPlayerApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      SleeperPlayerApiWeb.Telemetry,
      # Start the Ecto repository
      SleeperPlayerApi.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: SleeperPlayerApi.PubSub},
      # Start Finch
      {Finch, name: SleeperPlayerApi.Finch},
      # Start the Endpoint (http/https)
      SleeperPlayerApiWeb.Endpoint,
      # Start Quantum scheduler
      SleeperPlayerApi.Scheduler
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SleeperPlayerApi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SleeperPlayerApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
