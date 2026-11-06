defmodule TrackAnalyzer.Tracks.GPSGlitchTest do
  use ExUnit.Case, async: true

  alias TrackAnalyzer.FITFixture
  alias TrackAnalyzer.Tracks.{Analyzer, FIT}

  # The fixture rides north at 6 m/s (GPS) with a wheel sensor reading 6.12 m/s
  # and an odometer advancing 6.12 m per 1 s record.
  @count 400
  @odometer_m (@count - 1) * 6.12
  @degrees_per_m 1 / 111_195.08

  setup %{tmp_dir: dir} do
    {:ok, parsed} = dir |> FITFixture.write!("ride.fit", count: @count) |> FIT.parse_file()
    %{parsed: parsed}
  end

  defp gps_only(parsed) do
    %{
      parsed
      | points: Enum.map(parsed.points, &%{&1 | sensor_speed_mps: nil, sensor_distance_m: nil})
    }
  end

  # The receiver logs a stale position for 10 s, then jumps ~550 m to the real
  # one; from there the track is correct. Like the 2026-10-23 21:04 ride.
  defp startup_jump(parsed) do
    [first | _] = parsed.points

    points =
      parsed.points
      |> Enum.with_index()
      |> Enum.map(fn
        {point, index} when index < 10 -> %{point | latitude: first.latitude}
        {point, _index} -> %{point | latitude: point.latitude + 550 * @degrees_per_m}
      end)

    %{parsed | points: points}
  end

  defp move(parsed, from_index, to_index, meters) do
    points =
      parsed.points
      |> Enum.with_index()
      |> Enum.map(fn
        {point, index} when index >= from_index and index <= to_index ->
          %{point | latitude: point.latitude + meters * @degrees_per_m}

        {point, _index} ->
          point
      end)

    %{parsed | points: points}
  end

  defp kmh(mps), do: mps * 3.6

  describe "with a wheel sensor" do
    @describetag :tmp_dir

    test "distance, max speed and efforts come from the sensor, not from a GPS jump", %{
      parsed: parsed
    } do
      summary = parsed |> startup_jump() |> Analyzer.analyze() |> Map.fetch!(:summary)

      assert summary.stats["distance_source"] == "odometer"
      assert summary.stats["speed_source"] == "sensor"
      assert_in_delta summary.distance_m, @odometer_m, 0.01
      assert_in_delta summary.max_speed_mps, 6.12, 0.001
      # A window ends on the first record past 1 km, so it reads a touch low.
      assert_in_delta summary.best_1km_speed_mps, 6.12, 0.05
      assert summary.quality["gps_warmup_points"] == 10
    end

    test "an odometer reset falls back to wheel speed instead of counting backwards", %{
      parsed: parsed
    } do
      points =
        parsed.points
        |> Enum.with_index()
        |> Enum.map(fn
          {point, index} when index >= 200 -> %{point | sensor_distance_m: (index - 200) * 6.12}
          {point, _index} -> point
        end)

      summary = Analyzer.analyze(%{parsed | points: points}).summary
      assert_in_delta summary.distance_m, @odometer_m, 0.5
    end
  end

  describe "GPS only" do
    @describetag :tmp_dir

    test "points before the first good fix are ignored, and the jump is not distance", %{
      parsed: parsed
    } do
      result = parsed |> gps_only() |> startup_jump() |> Analyzer.analyze()
      summary = result.summary

      assert summary.stats["distance_source"] == "gps"
      assert summary.quality["gps_warmup_points"] == 10
      # 389 real 6 m steps after the fix; none of the 550 m jump.
      assert_in_delta summary.distance_m, 389 * 6.0, 2.0
      assert kmh(summary.max_speed_mps) < 25
      assert_in_delta summary.best_1km_speed_mps, 6.0, 0.05
      refute Enum.any?(Enum.take(result.points, 10), & &1.valid)
    end

    test "a lone spike is rejected and adds no distance", %{parsed: parsed} do
      summary =
        parsed |> gps_only() |> move(200, 200, 220) |> Analyzer.analyze() |> Map.fetch!(:summary)

      assert summary.quality["invalid_spike_points"] == 1
      assert_in_delta summary.distance_m, (@count - 1) * 6.0, 2.0
      assert kmh(summary.max_speed_mps) < 25
    end

    test "when the receiver relocates for good, the track continues without the jump", %{
      parsed: parsed
    } do
      summary =
        parsed
        |> gps_only()
        |> move(200, @count, 220)
        |> Analyzer.analyze()
        |> Map.fetch!(:summary)

      assert summary.quality["invalid_spike_points"] == 1
      # Only the step into the rejected fix is lost; the track resumes from it.
      assert_in_delta summary.distance_m, (@count - 2) * 6.0, 2.0
      assert kmh(summary.max_speed_mps) < 25
    end

    test "steps up to the plausibility limit are kept, faster ones are not", %{parsed: parsed} do
      limit_kmh = Analyzer.max_plausible_speed_mps() * 3.6
      assert limit_kmh == 80

      for {step_kmh, valid?} <- [{75, true}, {85, false}] do
        extra_m = step_kmh / 3.6 - 6.0
        result = parsed |> gps_only() |> move(200, 200, extra_m) |> Analyzer.analyze()
        assert Enum.at(result.points, 200).valid == valid?, "#{step_kmh} km/h step"
      end
    end
  end

  @tag :tmp_dir
  test "best efforts start at 1 km", %{parsed: parsed} do
    result = Analyzer.analyze(parsed)

    distances =
      result.splits |> Enum.filter(&(&1.kind == "best_effort")) |> Enum.map(& &1.position)

    assert distances == [1_000]
    assert result.summary.best_5km_speed_mps == nil
  end

  @tag :tmp_dir
  test "near-empty tracks get a reason to be skipped" do
    assert Analyzer.skip_reason(1, 0.0, 0.0) == "only 1 point"
    assert Analyzer.skip_reason(9, 5_000.0, 900.0) == "only 9 points"
    assert Analyzer.skip_reason(25, 77.4, 66.0) == "only 77 m long"
    assert Analyzer.skip_reason(40, 450.0, 45.0) == "only 45 s of movement"
    assert Analyzer.skip_reason(10, 200.0, 60.0) == nil
  end
end
