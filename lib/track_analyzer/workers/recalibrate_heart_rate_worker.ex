defmodule TrackAnalyzer.Workers.RecalibrateHeartRateWorker do
  @moduledoc false
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TrackAnalyzer.Tracks.HeartRates.recalibrate()
end
