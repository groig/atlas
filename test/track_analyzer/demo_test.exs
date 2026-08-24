defmodule TrackAnalyzer.DemoTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.Demo
  alias TrackAnalyzer.Imports.OSF
  alias TrackAnalyzer.Tracks.{Analyzer, GPX}

  @tag :tmp_dir
  test "generates a valid synthetic OsmAnd archive around Copenhagen", %{tmp_dir: directory} do
    path = Demo.write_archive!(Path.join(directory, "demo.osf"), 2)

    assert {:ok, inspection} = OSF.inspect(path)
    assert inspection.version == 3
    assert length(inspection.items) == 2
    assert Enum.all?(inspection.items, &String.starts_with?(&1["archive_path"], "tracks/demo/"))

    first = hd(inspection.items)
    assert {:ok, gpx} = OSF.read_gpx(path, first["archive_path"])
    gpx_path = Path.join(directory, "demo.gpx")
    File.write!(gpx_path, gpx)

    assert {:ok, parsed} = GPX.parse_file(gpx_path)
    analysis = Analyzer.analyze(parsed)
    assert String.starts_with?(analysis.summary.name, "DEMO · ")
    assert analysis.summary.point_count == 220
    assert analysis.summary.best_100m_speed_mps > 0
    assert analysis.summary.best_500m_speed_mps > 0
    assert analysis.summary.bounds["min_lat"] > 55.60
    assert analysis.summary.bounds["max_lat"] < 55.75
    assert analysis.summary.bounds["min_lon"] > 12.45
    assert analysis.summary.bounds["max_lon"] < 12.70
  end
end
