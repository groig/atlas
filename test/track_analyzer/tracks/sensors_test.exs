defmodule TrackAnalyzer.Tracks.SensorsTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.FITFixture
  alias TrackAnalyzer.Tracks.{Analyzer, FIT, GPX, Sensors}

  @tag :tmp_dir
  test "summarizes pedaling, coasting, gearing and terrain", %{tmp_dir: dir} do
    {:ok, parsed} = dir |> FITFixture.write!() |> FIT.parse_file()
    result = Analyzer.analyze(parsed)
    cadence = result.summary.stats["cadence"]

    assert cadence["sample_count"] == 120
    assert cadence["average_rpm"] == 85.0
    assert_in_delta cadence["coasting_percent"], 20.0, 1.5
    assert_in_delta cadence["moving_average_rpm"], 68.0, 1.5
    assert cadence["maximum_rpm"] == 85.0
    assert_in_delta cadence["revolutions"], 85 * 95 / 60, 2

    # 6.12 m/s at 85 rpm is 4.32 m per pedal stroke.
    assert_in_delta cadence["development_mode_m"], 4.32, 0.13
    assert [%{"meters" => 4.25, "seconds" => seconds}] = cadence["development"]
    assert seconds > 0

    assert [%{"rpm" => 80, "speed_kmh" => kmh}] = cadence["histogram"]
    assert_in_delta kmh, 22.0, 0.1
    assert Enum.map(cadence["terrain"], & &1["band"]) == ~w(descent flat rolling climb)
    assert Enum.find(cadence["terrain"], &(&1["band"] == "flat"))["average_rpm"] == 85.0
  end

  @tag :tmp_dir
  test "compares device distance and speed with GPS", %{tmp_dir: dir} do
    {:ok, parsed} = dir |> FITFixture.write!("ride.fit", count: 240) |> FIT.parse_file()
    speed = Analyzer.analyze(parsed).summary.stats["speed_sensor"]

    assert speed["distance_source"] == "device"
    # The fixture's odometer runs 2% long against its positions.
    assert_in_delta speed["distance_difference_percent"], 2.0, 0.2
    assert_in_delta speed["calibration_factor"], 1 / 1.02, 0.002
    assert_in_delta speed["maximum_kmh"], 22.03, 0.01
    assert_in_delta speed["median_difference_kmh"], 0.43, 0.05
    assert speed["within_10_percent"] == 100.0
    assert speed["gps_gap_s"] == 0.0
  end

  test "tracks without sensors report zero samples and keep their shape" do
    points =
      for i <- 0..5 do
        %{
          track_position: 0,
          segment_position: 0,
          latitude: 55.0 + i * 0.0005,
          longitude: 12.0,
          elevation_m: 10.0,
          recorded_at: DateTime.add(~U[2026-01-01 00:00:00Z], i * 10),
          hdop: nil,
          recorded_speed_mps: nil,
          extras: %{}
        }
      end

    parsed = %{
      name: "Plain",
      creator: nil,
      activity_type: nil,
      points: points,
      segments: [%{track_position: 0, position: 0}],
      invalid_point_count: 0,
      warnings: []
    }

    result = Analyzer.analyze(parsed)
    assert result.summary.stats["cadence"] == %{"sample_count" => 0}
    assert result.summary.stats["speed_sensor"] == %{"sample_count" => 0}
    assert Enum.all?(result.points, &(Map.has_key?(&1, :cadence_rpm) and is_nil(&1.cadence_rpm)))
  end

  test "normalizers reject impossible readings" do
    assert Sensors.normalize_cadence("90") == 90.0
    assert Sensors.normalize_cadence(0) == 0.0
    assert Sensors.normalize_cadence(400) == nil
    assert Sensors.normalize_cadence("pedal") == nil
    assert Sensors.normalize_speed(-1) == nil
    assert Sensors.normalize_speed("7.5") == 7.5
  end

  @tag :tmp_dir
  test "reads Garmin cadence and wheel-sensor speed from GPX extensions", %{tmp_dir: dir} do
    path = Path.join(dir, "sensors.gpx")

    File.write!(path, """
    <gpx xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xmlns:osmand="https://osmand.net">
      <trk><name>Commute</name><trkseg>
        <trkpt lat="55" lon="12"><time>2026-01-01T00:00:00Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:cad>88</gpxtpx:cad></gpxtpx:TrackPointExtension></extensions></trkpt>
        <trkpt lat="55.0001" lon="12"><time>2026-01-01T00:00:02Z</time><extensions><osmand:cadence>0</osmand:cadence><osmand:speed_sensor>5.5</osmand:speed_sensor></extensions></trkpt>
        <trkpt lat="55.0002" lon="12"><time>2026-01-01T00:00:04Z</time><extensions><gpxtpx:cad>999</gpxtpx:cad></extensions></trkpt>
      </trkseg></trk>
    </gpx>
    """)

    assert {:ok, parsed} = GPX.parse_file(path)
    assert parsed.name == "Commute"
    assert Enum.map(parsed.points, & &1.cadence_rpm) == [88.0, 0.0, nil]
    assert Enum.map(parsed.points, & &1.sensor_speed_mps) == [nil, 5.5, nil]
    assert Enum.map(parsed.points, & &1.recorded_speed_mps) == [nil, nil, nil]

    result = Analyzer.analyze(parsed)
    assert result.summary.quality["sensors"]["cadence_invalid_samples"] == 1
  end
end
