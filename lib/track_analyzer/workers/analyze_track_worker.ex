defmodule TrackAnalyzer.Workers.AnalyzeTrackWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :analysis,
    max_attempts: 2,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:track_id],
      states: :incomplete
    ]

  alias TrackAnalyzer.Imports
  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.{Analyzer, FIT, GPX, HeartRates}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => track_id}}) do
    track = Tracks.get_track(track_id)

    cond do
      is_nil(track) ->
        :ok

      track.status == "complete" and track.analysis_version == Analyzer.analysis_version() ->
        :ok

      true ->
        analyze(track)
    end
  rescue
    error -> fail_track(Tracks.get_track(track_id), error)
  end

  defp analyze(track) do
    with {:ok, track} <-
           Tracks.update_status(track, %{
             status: "parsing",
             stage: "Reading #{String.upcase(track.source_format || "gpx")} points",
             progress: 12
           }),
         {:ok, parsed} <- parse(track),
         {:ok, track} <-
           Tracks.update_status(track, %{
             status: "analyzing",
             stage: "Finding climbs, stops, efforts, and route patterns",
             progress: 48
           }),
         result <- Analyzer.analyze(parsed, heart_rate_profile: HeartRates.profile()),
         {:ok, track} <-
           Tracks.update_status(track, %{
             status: "indexing",
             stage: "Building maps and charts",
             progress: 82
           }),
         {:ok, track} <- Tracks.persist_analysis(track, result) do
      if track.status == "insufficient_data",
        do: Imports.mark_track_items(track.id, "skipped", track.quality["skip_reason"]),
        else: Imports.mark_track_items(track.id, "complete")

      schedule_route_progress_rebuild()
      :ok
    else
      {:error, reason} -> fail_track(track, reason)
    end
  end

  defp parse(%{source_format: "fit", original_path: path}), do: FIT.parse_file(path)
  defp parse(%{original_path: path}), do: GPX.parse_file(path)

  defp fail_track(nil, reason), do: {:discard, error_text(reason)}

  defp fail_track(track, reason) do
    message = error_text(reason)

    {:ok, _track} =
      Tracks.update_status(track, %{
        status: "failed",
        stage: "Analysis failed",
        progress: 100,
        error: message
      })

    Imports.mark_track_items(track.id, "failed", message)
    {:discard, message}
  end

  defp error_text(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(reason), do: inspect(reason)

  defp schedule_route_progress_rebuild do
    case TrackAnalyzer.Tracks.RouteProgress.enqueue_rebuild(delay: 15, reason: "track_analyzed") do
      {:ok, _job} -> :ok
      {:error, _changeset} -> :ok
    end
  end
end
