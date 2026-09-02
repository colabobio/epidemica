defmodule EpidemicaServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EpidemicaServerWeb.Telemetry,
      EpidemicaServer.Repo,
      {DNSCluster, query: Application.get_env(:epidemica_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EpidemicaServer.PubSub},
      {Oban, Application.fetch_env!(:epidemica_server, Oban)},
      # Start a worker by calling: EpidemicaServer.Worker.start_link(arg)
      # {EpidemicaServer.Worker, arg},
      # Start to serve requests, typically the last entry
      EpidemicaServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EpidemicaServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EpidemicaServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
