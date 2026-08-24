defmodule TrackAnalyzer.TrackFixture do
  @moduledoc false

  def gpx do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OsmAnd test" xmlns="http://www.topografix.com/GPX/1/1" xmlns:osmand="https://osmand.net">
      <metadata><name>Morning Loop</name></metadata>
      <trk><name>Morning Loop</name><trkseg>
        <trkpt lat="55.676100" lon="12.568300"><ele>12.0</ele><time>2025-01-15T08:00:00Z</time><hdop>2.0</hdop><extensions><osmand:speed>4.0</osmand:speed></extensions></trkpt>
        <trkpt lat="55.677100" lon="12.569300"><ele>18.0</ele><time>2025-01-15T08:00:30Z</time><hdop>2.5</hdop><extensions><osmand:speed>5.0</osmand:speed></extensions></trkpt>
        <trkpt lat="55.678100" lon="12.570300"><ele>16.0</ele><time>2025-01-15T08:01:00Z</time><hdop>3.0</hdop><extensions><osmand:speed>4.5</osmand:speed></extensions></trkpt>
      </trkseg></trk>
    </gpx>
    """
  end

  def write_gpx!(directory) do
    path = Path.join(directory, "morning_loop.gpx")
    File.write!(path, gpx())
    path
  end

  def write_osf!(directory, options \\ []) do
    manifest = %{
      "version" => Keyword.get(options, :version, 3),
      "items" => [
        %{
          "type" => "GPX",
          "subtype" => "gpx",
          "file" => "/tracks/rec/morning_loop.gpx",
          "total_distance" => 300.0,
          "time_span" => 60_000
        }
      ]
    }

    entries = [
      {~c"items.json", Jason.encode!(manifest)},
      {~c"tracks/rec/morning_loop.gpx", gpx()}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"fixture.osf", entries, [:memory])
    path = Path.join(directory, "fixture.osf")
    File.write!(path, binary)
    path
  end
end
