defmodule TrackAnalyzerWeb.ProgressLiveTest do
  use TrackAnalyzerWeb.ConnCase, async: true

  alias TrackAnalyzer.Repo

  alias TrackAnalyzer.Tracks.{
    Analyzer,
    Rendering,
    RouteCluster,
    RouteClusterMembership,
    Track
  }

  test "progress hub and route detail expose stable analysis surfaces", %{conn: conn} do
    first = insert_track!(0, 5.0)
    second = insert_track!(1, 5.4)
    insert_rendering!(first)
    insert_rendering!(second)

    cluster =
      %RouteCluster{}
      |> RouteCluster.changeset(%{
        name: "Test loop",
        fingerprint: "test-route-#{System.unique_integer([:positive])}",
        track_count: 2,
        representative_track_id: first.id,
        matcher_version: 1,
        activity_type: "cycling",
        stats: %{"average_similarity" => 0.94, "confidence" => "low"}
      })
      |> Repo.insert!()

    for {track, similarity} <- [{first, 1.0}, {second, 0.94}] do
      %RouteClusterMembership{}
      |> RouteClusterMembership.changeset(%{
        route_cluster_id: cluster.id,
        track_id: track.id,
        similarity: similarity,
        metrics: %{}
      })
      |> Repo.insert!()
    end

    {:ok, hub, _html} = live(conn, ~p"/progress")
    assert has_element?(hub, "#progress-hub")
    assert has_element?(hub, "#progress-volume-chart[data-volume]")
    assert has_element?(hub, "#progress-filters")

    assert has_element?(
             hub,
             "#matched-route-#{cluster.id}[href='/progress/routes/#{cluster.id}']"
           )

    assert has_element?(hub, "#speed-history-link[href='/speed']")

    {:ok, detail, _html} = live(conn, ~p"/progress/routes/#{cluster.id}")
    assert has_element?(detail, "#route-progress-detail")
    assert has_element?(detail, "#route-progress-map[data-sectors]")
    assert has_element?(detail, "#route-sector-chart[data-sectors]")
    assert has_element?(detail, "#route-trend-chart[data-history]")
    assert has_element?(detail, "#route-attempts")

    {:ok, track_detail, _html} = live(conn, ~p"/tracks/#{second.id}")

    assert has_element?(
             track_detail,
             "#track-matched-route[href='/progress/routes/#{cluster.id}']"
           )
  end

  defp insert_track!(index, speed) do
    %Track{}
    |> Track.changeset(%{
      sha256: "progress-live-#{System.unique_integer([:positive])}",
      original_path: "/tmp/progress-live-#{index}.gpx",
      source_filename: "progress-live-#{index}.gpx",
      name: "Test attempt #{index}",
      status: "complete",
      stage: "Ready to explore",
      progress: 100,
      analysis_version: Analyzer.analysis_version(),
      activity_type: "cycling",
      started_at: DateTime.add(~U[2026-01-01 08:00:00Z], index, :day),
      ended_at: DateTime.add(~U[2026-01-01 08:05:00Z], index, :day),
      point_count: 3,
      distance_m: 1_500.0,
      moving_s: 1_500.0 / speed,
      avg_speed_mps: speed,
      quality_score: 95.0,
      stats: %{"loop_score" => 0.0}
    })
    |> Repo.insert!()
  end

  defp insert_rendering!(track) do
    points = [{12.0, 55.0}, {12.01, 55.005}, {12.02, 55.01}]

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
          ],
          "time" => [
            DateTime.to_iso8601(track.started_at),
            track.started_at |> DateTime.add(150, :second) |> DateTime.to_iso8601(),
            DateTime.to_iso8601(track.ended_at)
          ]
        }
      }
      |> Repo.insert!()
    end
  end
end
