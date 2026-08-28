defmodule TrackAnalyzer.Workers.RebuildRouteClustersWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  alias TrackAnalyzer.Tracks.RouteProgress

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _result} = RouteProgress.rebuild()
    :ok
  end
end
