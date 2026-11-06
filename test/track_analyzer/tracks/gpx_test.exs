defmodule TrackAnalyzer.Tracks.GPXTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.TrackFixture
  alias TrackAnalyzer.Tracks.{Analyzer, GPX}

  @tag :tmp_dir
  test "streams OsmAnd extensions and derives rich track metrics", %{tmp_dir: directory} do
    path = TrackFixture.write_gpx!(directory)

    assert {:ok, parsed} = GPX.parse_file(path)
    assert parsed.name == "Morning Loop"
    assert parsed.creator == "OsmAnd test"
    assert parsed.activity_type == "cycling"
    assert length(parsed.points) == 12

    assert Enum.all?(parsed.points, fn point ->
             point.latitude >= 55.60 and point.latitude <= 55.75 and
               point.longitude >= 12.45 and point.longitude <= 12.70
           end)

    assert hd(parsed.points).recorded_speed_mps == 4.0
    assert hd(parsed.points).recorded_at.microsecond == {0, 6}

    analysis = Analyzer.analyze(parsed)
    assert analysis.summary.point_count == 12
    assert analysis.summary.distance_m > 250
    assert analysis.summary.elevation_gain_m == 6.0
    assert analysis.summary.quality_score == 100.0
    assert analysis.summary.analysis_version == Analyzer.analysis_version()
    assert analysis.summary.activity_type == "cycling"
    assert analysis.summary.max_speed_mps > 0
    assert analysis.summary.best_1km_speed_mps > 0
    assert analysis.summary.best_5km_speed_mps == nil
    assert analysis.summary.max_speed_confidence in ~w(high medium low)
    detail = Enum.find(analysis.renderings, &(&1.level == "detail"))
    assert detail.point_count == length(Polyline.decode(detail.encoded_polyline))

    for series_name <-
          ~w(distance_km elevation_m speed_kmh grade_percent time heart_rate_bpm hr_break hr_jump position) do
      assert length(detail.series[series_name]) == detail.point_count
    end

    assert analysis.cells != []
  end

  @tag :tmp_dir
  test "reads namespaced Garmin and OsmAnd HR without losing original extension values", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "synthetic_hr.gpx")

    File.write!(path, """
    <gpx xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xmlns:osmand="https://osmand.net">
      <trk><trkseg>
        <trkpt lat="55" lon="12"><time>2026-01-01T00:00:00Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>123</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
        <trkpt lat="55.0001" lon="12"><time>2026-01-01T00:00:06Z</time><extensions><osmand:hr>135</osmand:hr></extensions></trkpt>
        <trkpt lat="55.0002" lon="12"><time>2026-01-01T00:00:12Z</time><extensions><gpxtpx:hr>0</gpxtpx:hr></extensions></trkpt>
        <trkpt lat="55.0003" lon="12"><time>2026-01-01T00:00:18Z</time><extensions><gpxtpx:hr>broken</gpxtpx:hr></extensions></trkpt>
      </trkseg></trk>
    </gpx>
    """)

    assert {:ok, parsed} = GPX.parse_file(path)
    assert Enum.map(parsed.points, & &1.heart_rate_bpm) == [123.0, 135.0, nil, nil]
    assert Enum.map(parsed.points, & &1.extras["hr"]) == ["123", "135", "0", "broken"]
    result = Analyzer.analyze(parsed)
    assert result.summary.stats["heart_rate"]["average_bpm"] == 129.0
    assert result.summary.quality["heart_rate"]["invalid_samples"] == 2
  end

  @tag :tmp_dir
  test "rejects documents with a doctype", %{tmp_dir: directory} do
    path = Path.join(directory, "unsafe.gpx")
    File.write!(path, "<!DOCTYPE gpx><gpx></gpx>")
    assert {:error, :doctype_not_allowed} = GPX.parse_file(path)
  end

  @tag :tmp_dir
  test "downsampling preserves HR gaps and chart/map indexes", %{tmp_dir: directory} do
    {:ok, parsed} = directory |> TrackFixture.write_gpx!() |> GPX.parse_file()
    template = hd(parsed.points)

    points =
      for i <- 0..1200 do
        %{
          template
          | latitude: 55.0 + i * 0.0001,
            longitude: 12.0,
            recorded_at: DateTime.add(template.recorded_at, i * 6),
            heart_rate_bpm: if(i == 101, do: nil, else: 130.0),
            extras: %{}
        }
      end

    result = Analyzer.analyze(%{parsed | points: points})
    rendering = Enum.find(result.renderings, &(&1.level == "overview"))
    index = Enum.find_index(rendering.series["position"], &(&1 == 102))
    assert Enum.at(rendering.series["hr_break"], index)
    assert Enum.at(rendering.series["heart_rate_bpm"], index) == 130.0
    assert length(Polyline.decode(rendering.encoded_polyline)) == rendering.point_count

    assert Enum.all?(rendering.series, fn {_key, values} ->
             length(values) == rendering.point_count
           end)
  end

  @tag :tmp_dir
  test "uses OsmAnd route metadata when activity metadata is absent", %{tmp_dir: directory} do
    path = Path.join(directory, "route-fallback.gpx")

    File.write!(
      path,
      """
      <gpx version="1.1" creator="OsmAnd" xmlns:osmand="https://osmand.net">
        <metadata><extensions><osmand:route>Mountain Bike</osmand:route></extensions></metadata>
        <trk><trkseg><trkpt lat="55.0" lon="12.0" /></trkseg></trk>
      </gpx>
      """
    )

    assert {:ok, parsed} = GPX.parse_file(path)
    assert parsed.activity_type == "mountain_bike"
  end
end
