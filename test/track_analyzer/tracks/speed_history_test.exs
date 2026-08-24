defmodule TrackAnalyzer.Tracks.SpeedHistoryTest do
  use TrackAnalyzer.DataCase, async: true

  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.{Analyzer, Track}

  test "builds rolling and cumulative history across selectable speed measures" do
    tracks =
      for index <- 0..30 do
        insert_track!(index, %{
          max_speed_mps: 10.0 + index / 10,
          best_100m_speed_mps: 8.0 + index / 10,
          best_500m_speed_mps: 6.0 + index / 10
        })
      end

    history = Tracks.speed_history(%{"metric" => "100m", "range" => "all"})

    assert history.metric == "100m"
    assert length(history.points) == 31
    assert List.last(history.points).record_mps == 11.0
    assert List.last(history.points).rolling_median_mps == 10.3
    assert history.records.best_100m.track_id == List.last(tracks).id
    assert hd(history.leaders).id == List.last(tracks).id
    assert history.recent_delta_percent > 0

    instantaneous = Tracks.speed_history(%{"metric" => "instantaneous", "range" => "all"})
    assert instantaneous.metric == "instantaneous"
    assert hd(instantaneous.leaders).max_speed_mps == 13.0
  end

  test "filters history windows and queues only stale analyses" do
    old = insert_track!(0, %{started_at: ~U[2024-01-01 08:00:00Z], analysis_version: 1})
    recent = insert_track!(1, %{started_at: DateTime.add(DateTime.utc_now(), -10, :day)})

    history = Tracks.speed_history(%{"metric" => "500m", "range" => "90d"})
    assert Enum.map(history.points, & &1.track_id) == [recent.id]

    assert {:ok, %{stale_count: 1, enqueued_count: 1}} = Tracks.enqueue_stale_analyses()
    assert Repo.aggregate(Oban.Job, :count, :id) == 1
    assert old.analysis_version < Analyzer.analysis_version()
  end

  defp insert_track!(index, overrides) do
    defaults = %{
      sha256: "speed-history-#{System.unique_integer([:positive])}-#{index}",
      original_path: "/tmp/synthetic-#{index}.gpx",
      source_filename: "synthetic-#{index}.gpx",
      source_folder: "tracks/demo",
      name: "DEMO · Track #{index}",
      status: "complete",
      stage: "Ready to explore",
      progress: 100,
      analysis_version: Analyzer.analysis_version(),
      started_at: DateTime.add(~U[2025-01-01 08:00:00Z], index * 7, :day),
      ended_at: DateTime.add(~U[2025-01-01 09:00:00Z], index * 7, :day),
      max_speed_mps: 10.0,
      best_100m_speed_mps: 8.0,
      best_500m_speed_mps: 6.0,
      max_speed_confidence: "high"
    }

    %Track{}
    |> Track.changeset(Map.merge(defaults, overrides))
    |> Repo.insert!()
  end
end
