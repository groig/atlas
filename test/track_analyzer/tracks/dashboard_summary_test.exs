defmodule TrackAnalyzer.Tracks.DashboardSummaryTest do
  use TrackAnalyzer.DataCase, async: true

  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.{Analyzer, Track}

  test "reports active processing and selects the latest completed track" do
    older = insert_track!(0, %{started_at: ~U[2025-01-01 08:00:00Z]})
    latest = insert_track!(1, %{started_at: ~U[2025-03-01 08:00:00Z]})
    _queued = insert_track!(2, %{status: "queued", progress: 0})
    _analyzing = insert_track!(3, %{status: "analyzing", progress: 60})
    _failed = insert_track!(4, %{status: "failed", progress: 100})

    summary = Tracks.portfolio_summary()

    assert summary.track_count == 2
    assert summary.processing_count == 2
    assert summary.earliest_at == older.started_at
    assert Tracks.latest_complete_track().id == latest.id
  end

  test "returns no latest track when analysis has not completed" do
    _queued = insert_track!(0, %{status: "queued", progress: 0})

    assert Tracks.latest_complete_track() == nil
    assert Tracks.portfolio_summary().processing_count == 1
  end

  test "builds a privacy-safe weighted recap summary" do
    _first =
      insert_track!(0, %{
        distance_m: 1_000.0,
        moving_s: 100.0,
        elevation_gain_m: 80.0,
        max_speed_mps: 12.0,
        best_100m_speed_mps: 10.0,
        best_500m_speed_mps: 7.0,
        quality_score: 90.0
      })

    _second =
      insert_track!(1, %{
        distance_m: 2_000.0,
        moving_s: 400.0,
        elevation_gain_m: 140.0,
        max_speed_mps: 15.0,
        best_100m_speed_mps: 9.0,
        best_500m_speed_mps: 8.0,
        quality_score: 100.0,
        max_speed_confidence: "medium"
      })

    summary = Tracks.share_summary(:all)

    assert summary.track_count == 2
    assert summary.distance_m == 3_000.0
    assert summary.moving_s == 500.0
    assert summary.elevation_gain_m == 220.0
    assert summary.avg_speed_mps == 6.0
    assert summary.max_speed_mps == 15.0
    assert summary.max_speed_confidence == "medium"
    assert summary.best_100m_speed_mps == 10.0
    assert summary.best_500m_speed_mps == 8.0
    assert summary.longest_distance_m == 2_000.0
    assert summary.highest_elevation_gain_m == 140.0
    assert summary.longest_moving_s == 400.0
    assert summary.quality_score == 95.0

    assert Enum.all?(summary.activity, fn activity ->
             Map.keys(activity) |> Enum.sort() == [:distance_m, :started_at]
           end)

    refute Map.has_key?(summary, :name)
    refute Map.has_key?(summary, :track_id)
    refute Map.has_key?(summary, :bounds)
  end

  test "uses inclusive start and exclusive end calendar bounds" do
    from = ~U[2026-01-01 05:00:00Z]
    until = ~U[2027-01-01 05:00:00Z]

    included = insert_track!(0, %{started_at: from, distance_m: 1_000.0})
    _inside = insert_track!(1, %{started_at: ~U[2026-08-25 14:00:00Z], distance_m: 2_000.0})
    _excluded_at_end = insert_track!(2, %{started_at: until, distance_m: 4_000.0})
    _excluded_without_date = insert_track!(3, %{started_at: nil, distance_m: 8_000.0})
    _excluded_processing = insert_track!(4, %{started_at: from, status: "analyzing"})

    summary = Tracks.share_summary(%{from: from, until: until})

    assert summary.track_count == 2
    assert summary.distance_m == 3_000.0
    assert hd(summary.activity).started_at == included.started_at
  end

  test "returns a stable empty recap" do
    assert %{
             track_count: 0,
             distance_m: 0,
             moving_s: 0,
             elevation_gain_m: 0,
             avg_speed_mps: nil,
             max_speed_mps: nil,
             activity: []
           } = Tracks.share_summary(:all)
  end

  defp insert_track!(index, overrides) do
    defaults = %{
      sha256: "dashboard-summary-#{System.unique_integer([:positive])}-#{index}",
      original_path: "/tmp/dashboard-summary-#{index}.gpx",
      source_filename: "dashboard-summary-#{index}.gpx",
      source_folder: "tracks/test",
      name: "Dashboard track #{index}",
      status: "complete",
      stage: "Ready to explore",
      progress: 100,
      analysis_version: Analyzer.analysis_version(),
      started_at: DateTime.add(~U[2025-01-01 08:00:00Z], index, :day),
      ended_at: DateTime.add(~U[2025-01-01 09:00:00Z], index, :day),
      point_count: 10,
      distance_m: 1_000.0,
      moving_s: 300.0,
      elevation_gain_m: 20.0,
      quality_score: 95.0,
      max_speed_confidence: "high"
    }

    %Track{}
    |> Track.changeset(Map.merge(defaults, overrides))
    |> Repo.insert!()
  end
end
