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
    assert length(parsed.points) == 3

    assert Enum.all?(parsed.points, fn point ->
             point.latitude >= 55.60 and point.latitude <= 55.75 and
               point.longitude >= 12.45 and point.longitude <= 12.70
           end)

    assert hd(parsed.points).recorded_speed_mps == 4.0
    assert hd(parsed.points).recorded_at.microsecond == {0, 6}

    analysis = Analyzer.analyze(parsed)
    assert analysis.summary.point_count == 3
    assert analysis.summary.distance_m > 250
    assert analysis.summary.elevation_gain_m == 6.0
    assert analysis.summary.quality_score == 100.0
    assert analysis.summary.analysis_version == 2
    assert analysis.summary.max_speed_mps > 0
    assert analysis.summary.best_100m_speed_mps > 0
    assert analysis.summary.best_500m_speed_mps == nil
    assert analysis.summary.max_speed_confidence in ~w(high medium low)
    detail = Enum.find(analysis.renderings, &(&1.level == "detail"))
    assert detail.point_count == length(Polyline.decode(detail.encoded_polyline))

    for series_name <- ~w(distance_km elevation_m speed_kmh grade_percent time) do
      assert length(detail.series[series_name]) == detail.point_count
    end

    assert analysis.cells != []
  end

  @tag :tmp_dir
  test "rejects documents with a doctype", %{tmp_dir: directory} do
    path = Path.join(directory, "unsafe.gpx")
    File.write!(path, "<!DOCTYPE gpx><gpx></gpx>")
    assert {:error, :doctype_not_allowed} = GPX.parse_file(path)
  end
end
