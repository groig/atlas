defmodule Mix.Tasks.TrackAnalyzer.Reanalyze do
  @moduledoc "Enqueues tracks whose persisted analysis version is stale."

  use Mix.Task

  @shortdoc "Enqueue stale tracks for analysis"

  @impl Mix.Task
  def run(arguments) do
    {_options, remaining, _invalid} = OptionParser.parse(arguments, strict: [stale: :boolean])

    if remaining != [] do
      Mix.raise("unexpected arguments: #{Enum.join(remaining, " ")}")
    end

    configure_enqueue_only()
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")
    {:ok, result} = TrackAnalyzer.Tracks.enqueue_stale_analyses()

    Mix.shell().info(
      "Found #{result.stale_count} stale tracks and enqueued #{result.enqueued_count} analysis jobs."
    )
  end

  defp configure_enqueue_only do
    config = Application.fetch_env!(:track_analyzer, Oban)

    Application.put_env(
      :track_analyzer,
      Oban,
      Keyword.merge(config, queues: false, plugins: false)
    )
  end
end
