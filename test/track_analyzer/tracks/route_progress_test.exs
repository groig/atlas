defmodule TrackAnalyzer.Tracks.RouteProgressTest do
  use TrackAnalyzer.DataCase, async: true

  alias TrackAnalyzer.Repo

  alias TrackAnalyzer.Tracks.{
    Analyzer,
    Rendering,
    RouteCluster,
    RouteProgress,
    Track
  }

  test "uses a route-specific noise floor for progress labels" do
    attempts =
      [5.0, 5.1, 4.9, 5.6, 5.7, 5.8]
      |> Enum.with_index()
      |> Enum.map(fn {speed, index} ->
        %Track{
          avg_speed_mps: speed,
          started_at: DateTime.add(~U[2026-01-01 08:00:00Z], index, :day)
        }
      end)

    trend = RouteProgress.trend(attempts)
    assert trend.direction == "faster"
    assert trend.signal == "recent 3 vs prior 3"
    assert trend.delta_percent > trend.noise_floor_percent
  end

  test "debounces pending rebuilds and lets a manual rebuild run immediately" do
    assert {:ok, first} = RouteProgress.enqueue_rebuild(delay: 15, reason: "first")
    assert first.state == "scheduled"

    assert {:ok, second} = RouteProgress.enqueue_rebuild(delay: 20, reason: "second")
    assert second.id == first.id
    assert DateTime.compare(second.scheduled_at, first.scheduled_at) == :gt
    assert Repo.aggregate(Oban.Job, :count, :id) == 1

    assert {:ok, immediate} = RouteProgress.enqueue_rebuild(reason: "manual")
    assert immediate.id == first.id
    assert immediate.state == "available"
  end

  test "rebuilds repeatable groups and preserves cluster identity and name" do
    first = insert_track!(0, 5.0)
    second = insert_track!(1, 5.4)
    insert_rendering!(first, 0.0)
    insert_rendering!(second, 0.0001)

    assert {:ok, %{cluster_count: 1, matched_track_count: 2}} = RouteProgress.rebuild()
    cluster = Repo.one!(RouteCluster)

    cluster
    |> RouteCluster.changeset(%{name: "Harbor commute"})
    |> Repo.update!()

    assert {:ok, %{cluster_count: 1}} = RouteProgress.rebuild()
    rebuilt = Repo.one!(RouteCluster)
    assert rebuilt.id == cluster.id
    assert rebuilt.name == "Harbor commute"

    detail = RouteProgress.get_cluster!(rebuilt.id)
    assert detail.track_count == 2
    assert length(detail.sectors) == 10
  end

  defp insert_track!(index, speed) do
    %Track{}
    |> Track.changeset(%{
      sha256: "route-progress-#{System.unique_integer([:positive])}",
      original_path: "/tmp/route-progress-#{index}.gpx",
      source_filename: "route-progress-#{index}.gpx",
      name: "Route attempt #{index}",
      status: "complete",
      stage: "Ready to explore",
      progress: 100,
      analysis_version: Analyzer.analysis_version(),
      activity_type: "cycling",
      started_at: DateTime.add(~U[2026-01-01 08:00:00Z], index, :day),
      ended_at: DateTime.add(~U[2026-01-01 08:30:00Z], index, :day),
      point_count: 20,
      distance_m: 1_500.0,
      moving_s: 1_500.0 / speed,
      avg_speed_mps: speed,
      quality_score: 95.0,
      stats: %{"loop_score" => 0.0}
    })
    |> Repo.insert!()
  end

  defp insert_rendering!(track, offset) do
    points = [
      {12.0000 + offset, 55.0000},
      {12.0100 + offset, 55.0050},
      {12.0200 + offset, 55.0100}
    ]

    for level <- ["overview", "detail"] do
      %Rendering{
        track_id: track.id,
        level: level,
        point_count: length(points),
        encoded_polyline: Polyline.encode(points),
        series: %{
          "distance_km" => [0.0, 0.75, 1.5],
          "speed_kmh" => [
            track.avg_speed_mps * 3.6,
            track.avg_speed_mps * 3.6,
            track.avg_speed_mps * 3.6
          ]
        }
      }
      |> Repo.insert!()
    end
  end
end
