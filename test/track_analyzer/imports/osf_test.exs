defmodule TrackAnalyzer.Imports.OSFTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.Imports.OSF
  alias TrackAnalyzer.TrackFixture

  @tag :tmp_dir
  test "accepts manifest-listed GPX files and normalizes OsmAnd paths", %{tmp_dir: directory} do
    path = TrackFixture.write_osf!(directory)

    assert {:ok, archive} = OSF.inspect(path)
    assert archive.version == 3
    assert [%{"archive_path" => "tracks/rec/morning_loop.gpx"}] = archive.items
    assert {:ok, gpx} = OSF.read_gpx(path, hd(archive.items)["archive_path"])
    assert gpx == TrackFixture.gpx()
  end

  @tag :tmp_dir
  test "warns without rejecting a newer OsmAnd manifest", %{tmp_dir: directory} do
    path = TrackFixture.write_osf!(directory, version: 4)
    assert {:ok, archive} = OSF.inspect(path)
    assert archive.warning =~ "newer"
  end

  @tag :tmp_dir
  test "rejects a ZIP that is not an OsmAnd export", %{tmp_dir: directory} do
    path = Path.join(directory, "not-osmand.osf")
    {:ok, {_name, binary}} = :zip.create(~c"invalid.osf", [{~c"readme.txt", "hello"}], [:memory])
    File.write!(path, binary)

    assert {:error, :missing_items_manifest} = OSF.inspect(path)
  end
end
