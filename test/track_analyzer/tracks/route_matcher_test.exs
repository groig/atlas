defmodule TrackAnalyzer.Tracks.RouteMatcherTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.Tracks.{Rendering, RouteMatcher, Track}

  test "matches same-direction routes with small geometry variation" do
    left = feature([{12.0000, 55.0000}, {12.0100, 55.0050}, {12.0200, 55.0100}])
    right = feature([{12.0002, 55.0001}, {12.0102, 55.0051}, {12.0202, 55.0101}])

    assert {:ok, match} = RouteMatcher.match(left, right)
    assert match.similarity > 0.8
    assert match.metrics["median_distance_m"] < 120
    assert match.metrics["p90_distance_m"] < 250
  end

  test "rejects a reversed open route" do
    points = [{12.0000, 55.0000}, {12.0100, 55.0050}, {12.0200, 55.0100}]
    assert :no_match = RouteMatcher.match(feature(points), feature(Enum.reverse(points)))
  end

  test "rejects different known activity types and implausible unknown-speed pairs" do
    cycling = feature([{12.0, 55.0}, {12.02, 55.01}], activity_type: "cycling")
    running = feature([{12.0, 55.0}, {12.02, 55.01}], activity_type: "running")
    assert :no_match = RouteMatcher.match(cycling, running)

    slow = feature([{12.0, 55.0}, {12.02, 55.01}], avg_speed_mps: 2.0)
    fast = feature([{12.0, 55.0}, {12.02, 55.01}], avg_speed_mps: 8.0)
    assert :no_match = RouteMatcher.match(slow, fast)
  end

  test "aligns loops at different start positions but rejects opposite direction" do
    points = [
      {12.0000, 55.0000},
      {12.0100, 55.0000},
      {12.0100, 55.0100},
      {12.0000, 55.0100},
      {12.0000, 55.0000}
    ]

    shifted = Enum.drop(points, 2) ++ Enum.slice(points, 1, 2)

    assert {:ok, _match} =
             RouteMatcher.match(feature(points, loop?: true), feature(shifted, loop?: true))

    assert :no_match =
             RouteMatcher.match(
               feature(points, loop?: true),
               feature(Enum.reverse(points), loop?: true)
             )
  end

  defp feature(points, options \\ []) do
    rendering = %Rendering{
      level: "overview",
      point_count: length(points),
      encoded_polyline: Polyline.encode(points)
    }

    track = %Track{
      id: System.unique_integer([:positive]),
      status: "complete",
      started_at: ~U[2026-01-01 08:00:00Z],
      distance_m: 1_500.0,
      moving_s: 300.0,
      avg_speed_mps: Keyword.get(options, :avg_speed_mps, 5.0),
      quality_score: 95.0,
      activity_type: Keyword.get(options, :activity_type),
      stats: %{"loop_score" => if(Keyword.get(options, :loop?, false), do: 1.0, else: 0.0)},
      renderings: [rendering]
    }

    assert {:ok, feature} = RouteMatcher.feature(track)
    feature
  end
end
