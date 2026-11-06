defmodule TrackAnalyzer.Tracks.FITTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.FITFixture
  alias TrackAnalyzer.Tracks.{Analyzer, FIT}

  @tag :tmp_dir
  test "reads positions, time and sensor channels from a FIT activity", %{tmp_dir: dir} do
    path = FITFixture.write!(dir, "ride.fit", count: 60, heart_rate: fn i -> 120 + i end)

    assert {:ok, parsed} = FIT.parse_file(path)
    assert parsed.warnings == []
    assert parsed.activity_type == "road_cycling"
    assert parsed.creator == "FIT · Garmin"
    assert parsed.name == nil
    assert length(parsed.points) == 60

    [first, second | _] = parsed.points
    assert_in_delta first.latitude, 55.0, 1.0e-6
    assert_in_delta first.longitude, 12.0, 1.0e-6
    assert first.recorded_at == ~U[2026-05-01 07:00:00.000000Z]
    assert DateTime.diff(second.recorded_at, first.recorded_at) == 1
    assert first.elevation_m == 20.0
    assert first.cadence_rpm == 85.0
    assert first.heart_rate_bpm == 120.0
    assert_in_delta first.sensor_speed_mps, 6.12, 0.001
    assert second.sensor_distance_m == 6.12

    # Every tenth pair of readings is coasting in the fixture.
    assert Enum.at(parsed.points, 8).cadence_rpm == 0.0
  end

  @tag :tmp_dir
  test "compressed timestamps and big-endian definitions decode identically", %{tmp_dir: dir} do
    {:ok, plain} = dir |> FITFixture.write!("plain.fit", count: 80) |> FIT.parse_file()

    {:ok, packed} =
      dir |> FITFixture.write!("packed.fit", count: 80, compressed: true) |> FIT.parse_file()

    {:ok, big} =
      dir |> FITFixture.write!("big.fit", count: 80, big_endian: true) |> FIT.parse_file()

    times = Enum.map(plain.points, & &1.recorded_at)
    assert Enum.map(packed.points, & &1.recorded_at) == times
    assert Enum.map(big.points, & &1.recorded_at) == times
    assert Enum.map(big.points, & &1.cadence_rpm) == Enum.map(plain.points, & &1.cadence_rpm)
  end

  @tag :tmp_dir
  test "damaged files keep their readable part and say so", %{tmp_dir: dir} do
    {:ok, corrupt} =
      dir |> FITFixture.write!("crc.fit", corrupt_crc: true) |> FIT.parse_file()

    assert length(corrupt.points) == 120
    assert Enum.any?(corrupt.warnings, &(&1 =~ "checksum"))

    {:ok, truncated} =
      dir |> FITFixture.write!("cut.fit", truncate: 400) |> FIT.parse_file()

    assert length(truncated.points) in 80..119
    assert Enum.any?(truncated.warnings, &(&1 =~ "truncated"))
  end

  @tag :tmp_dir
  test "rejects files that are not FIT", %{tmp_dir: dir} do
    path = Path.join(dir, "fake.fit")
    File.write!(path, "<gpx></gpx>")
    assert {:error, :not_a_fit_file} = FIT.parse_file(path)
    assert {:error, {:file_error, :enoent}} = FIT.parse_file(Path.join(dir, "missing.fit"))
  end

  @tag :tmp_dir
  test "a wheel sensor sets the peak, so a GPS spike cannot", %{tmp_dir: dir} do
    {:ok, parsed} = dir |> FITFixture.write!("ride.fit") |> FIT.parse_file()

    # Push one position forward so GPS sees a spike the wheel sensor did not.
    spiked =
      List.update_at(parsed.points, 60, fn point ->
        %{point | latitude: point.latitude + 0.0002}
      end)

    result = Analyzer.analyze(%{parsed | points: spiked})
    assert_in_delta result.summary.max_speed_mps, 6.12, 0.001
    assert result.summary.max_speed_confidence == "high"
    assert result.summary.stats["speed_source"] == "sensor"
  end

  @tag :tmp_dir
  test "without a wheel sensor, a GPS peak the device speed does not confirm is ignored", %{
    tmp_dir: dir
  } do
    {:ok, parsed} = dir |> FITFixture.write!("ride.fit") |> FIT.parse_file()

    # A 70 km/h step: plausible for a bike, so GPS keeps the fix, but the one
    # device reading left (at that fix) says 22 km/h.
    points =
      parsed.points
      |> Enum.map(&%{&1 | sensor_speed_mps: nil, sensor_distance_m: nil})
      |> List.update_at(60, fn point ->
        %{point | latitude: point.latitude + 0.00014, sensor_speed_mps: 6.12}
      end)

    result = Analyzer.analyze(%{parsed | points: points})
    assert result.summary.stats["speed_source"] == "gps"
    assert result.summary.max_speed_point_position != 60
    assert result.summary.max_speed_mps < 40 / 3.6
  end

  @example Path.expand("../../../priv/ride-0-2026-10-22-07-54-29.fit", __DIR__)
  if File.exists?(@example) do
    test "decodes the bundled example ride" do
      assert {:ok, parsed} = FIT.parse_file(@example)
      assert length(parsed.points) == 1881
      cadence = Analyzer.analyze(parsed).summary.stats["cadence"]
      # The recorder's own session summary says 72 rpm average, 122 rpm peak.
      assert round(cadence["average_rpm"]) == 72
      assert cadence["maximum_rpm"] == 122.0
    end
  end
end
