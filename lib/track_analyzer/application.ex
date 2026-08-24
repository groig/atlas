defmodule TrackAnalyzer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TrackAnalyzerWeb.Telemetry,
      TrackAnalyzer.Repo,
      {Oban, Application.fetch_env!(:track_analyzer, Oban)},
      {DNSCluster, query: Application.get_env(:track_analyzer, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TrackAnalyzer.PubSub},
      # Start a worker by calling: TrackAnalyzer.Worker.start_link(arg)
      # {TrackAnalyzer.Worker, arg},
      # Start to serve requests, typically the last entry
      TrackAnalyzerWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TrackAnalyzer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TrackAnalyzerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
