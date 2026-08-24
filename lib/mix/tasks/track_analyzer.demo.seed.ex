defmodule Mix.Tasks.TrackAnalyzer.Demo.Seed do
  @moduledoc "Seeds an isolated demo database with synthetic Copenhagen tracks."

  use Mix.Task

  @shortdoc "Seed privacy-safe screenshot data"

  @impl Mix.Task
  def run(_arguments) do
    config = Application.fetch_env!(:track_analyzer, Oban)

    Application.put_env(
      :track_analyzer,
      Oban,
      Keyword.merge(config, queues: false, plugins: false)
    )

    Logger.configure(level: :warning)
    Mix.Task.run("app.start")
    result = TrackAnalyzer.Demo.seed!()

    Mix.shell().info(
      "Synthetic Copenhagen demo is ready with #{result.track_count} analyzed tracks."
    )
  end
end
