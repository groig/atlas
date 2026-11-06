defmodule TrackAnalyzer.TrackFixture do
  @moduledoc false

  def gpx do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OsmAnd test" xmlns="http://www.topografix.com/GPX/1/1" xmlns:osmand="https://osmand.net">
      <metadata><name>Morning Loop</name><extensions><osmand:activity>cycling</osmand:activity></extensions></metadata>
      <trk><name>Morning Loop</name><trkseg>
    #{points()}
      </trkseg></trk>
    </gpx>
    """
  end

  # Twelve fixes 30 s apart, about 128 m each: long enough not to be skipped.
  defp points do
    for index <- 0..11 do
      elevation = Enum.at([12.0, 18.0], index, 16.0)
      time = DateTime.add(~U[2025-01-15 08:00:00Z], index * 30) |> DateTime.to_iso8601()
      hdop = Enum.at([2.0, 2.5], index, 3.0)
      speed = Enum.at([4.0, 5.0], index, 4.5)

      ~s(<trkpt lat="#{:erlang.float_to_binary(55.6761 + index * 0.001, decimals: 6)}" lon="#{:erlang.float_to_binary(12.5683 + index * 0.001, decimals: 6)}"><ele>#{elevation}</ele><time>#{time}</time><hdop>#{hdop}</hdop><extensions><osmand:speed>#{speed}</osmand:speed></extensions></trkpt>)
    end
    |> Enum.join("\n")
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
          "total_distance" => 1_400.0,
          "time_span" => 330_000
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
