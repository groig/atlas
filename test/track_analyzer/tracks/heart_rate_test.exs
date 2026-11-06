defmodule TrackAnalyzer.Tracks.HeartRateTest do
  use ExUnit.Case, async: true
  alias TrackAnalyzer.Tracks.HeartRate

  defp points(readings, options \\ []) do
    step = Keyword.get(options, :step, 6)

    readings
    |> Enum.with_index()
    |> Enum.map(fn {hr, i} ->
      %{
        position: i,
        recorded_at: DateTime.add(~U[2026-01-01 00:00:00Z], round(i * step * 1000), :millisecond),
        heart_rate_bpm: HeartRate.normalize(hr),
        extras: %{"hr" => hr, "delta_seconds" => step},
        segment_position: 0,
        cumulative_distance_m: i * step * 5.0,
        derived_speed_mps: 5.0,
        valid: true,
        grade_percent: 0.0
      }
    end)
    |> HeartRate.prepare()
  end

  test "normalizes readings and retains only plausible numeric observations" do
    assert HeartRate.normalize(" 132 ") == 132.0

    for value <- [nil, "", "132bpm", "oops", 0, 29, 241],
        do: assert(is_nil(HeartRate.normalize(value)))
  end

  test "time weights irregular readings and integrates distribution" do
    [a, b, c] = points([100, 120, 160])
    c = %{c | recorded_at: DateTime.add(a.recorded_at, 30)}
    result = HeartRate.analyze([a, b, c])
    assert_in_delta result.summary["average_bpm"], (110 * 6 + 140 * 24) / 30, 0.0001
    assert result.summary["covered_s"] == 30
    assert_in_delta Enum.sum(Enum.map(result.summary["histogram"], & &1["seconds"])), 30, 0.0001
    assert result.summary["load"] == nil
  end

  test "missing HR, long gaps, segment boundaries and repeated times are not bridged" do
    for transform <- [
          fn [a, b, c] -> [a, %{b | heart_rate_bpm: nil, extras: %{}}, c] end,
          fn [a, b, c] -> [a, %{b | recorded_at: DateTime.add(a.recorded_at, 60)}, c] end,
          fn [a, b, c] -> [a, %{b | segment_position: 1}, c] end,
          fn [a, b, c] ->
            [a, %{b | recorded_at: a.recorded_at}, %{c | recorded_at: a.recorded_at}]
          end
        ] do
      result =
        points([100, 110, 120]) |> transform.() |> HeartRate.prepare() |> HeartRate.analyze()

      assert result.summary["covered_s"] == 0
      assert result.summary["average_bpm"] == nil
    end
  end

  test "GPS rejection does not discard heart rate; suspect readings stay visible" do
    readings = points([80, 140, 145]) |> Enum.map(&%{&1 | valid: false})
    result = HeartRate.analyze(readings)
    assert result.summary["sample_count"] == 3
    assert result.summary["maximum_bpm"] == 145
    assert result.summary["moving_average_bpm"] == nil
    assert result.quality["suspect_transitions"] == 1
  end

  test "selection keeps GPS distance and speed when heart rate is missing" do
    readings = points([100, nil, 120, 130])
    result = HeartRate.selection(readings, hd(readings).recorded_at, 0, 18)
    assert result["distance_m"] == 90
    assert result["speed_kmh"] == 18
    assert result["covered_s"] == 6
    assert result["average_bpm"] == 125
  end

  test "duration curve includes maxima between sampled timestamps and cannot bridge gaps" do
    readings = points([100, 110, 130, 160, 130, 110, 100], step: 20)
    result = HeartRate.analyze(readings)
    minute = hd(result.summary["duration_curve"])
    assert_in_delta minute["start_s"], 30, 0.001
    assert_in_delta minute["average_bpm"], 138.333333, 0.001
    assert Enum.at(result.summary["duration_curve"], 1)["average_bpm"] == nil
    broken = List.update_at(readings, 3, &%{&1 | heart_rate_bpm: nil}) |> HeartRate.analyze()
    assert hd(broken.summary["duration_curve"])["average_bpm"] == nil
  end

  test "route sector coverage includes missing HR in the denominator" do
    readings = points(for i <- 0..150, do: if(rem(i, 2) == 0, do: 120))
    result = HeartRate.analyze(readings)
    assert result.summary["sectors"] != []
    assert Enum.all?(result.summary["sectors"], &(&1["moving_s"] > 0 and &1["eligible_s"] == 0))
  end

  test "millisecond timestamps remain one continuous run despite floating point rounding" do
    result = points(List.duplicate(135, 250), step: 6.037) |> HeartRate.analyze()
    assert Enum.all?(result.summary["duration_curve"], &is_number(&1["average_bpm"]))

    for effort <- result.summary["duration_curve"],
        do: assert_in_delta(effort["average_bpm"], 135, 0.0001)
  end

  test "drift requires a continuous steady flat window after warm-up" do
    short = points(List.duplicate(130, 350)) |> HeartRate.analyze()
    refute short.summary["drift"]["available"]
    long = points(for i <- 0..400, do: 120 + i / 40)
    result = HeartRate.analyze(long)
    assert result.summary["drift"]["available"]
    assert result.summary["drift"]["percent"] > 0
    hilly = Enum.map(long, &%{&1 | grade_percent: 8.0}) |> HeartRate.analyze()
    refute hilly.summary["drift"]["available"]
  end

  test "explicit bands calculate weighted minutes, not proprietary training scores" do
    summary = points(List.duplicate(135, 11)) |> HeartRate.analyze() |> Map.fetch!(:summary)

    result =
      HeartRate.with_zones(summary, %{"edges" => [30, 100, 120, 140, 160], "revision" => 2})

    assert result["load"] == 3.0
    assert result["zone_revision"] == 2
    assert Enum.at(result["zones"], 2)["seconds"] == 60
    assert HeartRate.with_zones(result, %{})["load"] == nil

    isolated =
      points([135, nil, 140]) |> HeartRate.analyze(%{"edges" => [30, 100, 120, 140, 160]})

    assert isolated.summary["load"] == nil
  end

  describe "cadence lock" do
    # 1 Hz samples: a list of {hr, cadence} pairs.
    defp ride(samples) do
      samples
      |> Enum.with_index()
      |> Enum.map(fn {{hr, cadence}, i} ->
        %{
          position: i,
          recorded_at: DateTime.add(~U[2026-11-03 21:38:48Z], i),
          heart_rate_bpm: hr * 1.0,
          cadence_rpm: cadence && cadence * 1.0,
          extras: %{"hr" => hr, "delta_seconds" => 1},
          segment_position: 0,
          cumulative_distance_m: i * 7.0,
          derived_speed_mps: 7.0,
          valid: true,
          grade_percent: 0.0
        }
      end)
      |> HeartRate.prepare()
    end

    defp locked(points), do: Enum.count(points, &HeartRate.cadence_lock?/1)

    test "HR tracking cadence for a minute is flagged, kept, and left out of the stats" do
      # 5 min of real HR around 140, then 90 s where the sensor reads cadence.
      honest = for _ <- 1..300, do: {140, 85}
      lock = for i <- 1..90, do: {84 + rem(i, 3), 83 + rem(i, 2)}
      points = ride(honest ++ lock ++ honest)

      assert locked(points) >= 90
      # The raw value is still there.
      assert Enum.at(points, 330).heart_rate_bpm in [84.0, 85.0, 86.0]

      result = HeartRate.analyze(points)
      assert_in_delta result.summary["average_bpm"], 140, 0.01
      assert result.summary["minimum_bpm"] == 140.0
      assert result.summary["cadence_lock"]["samples"] == locked(points)
      assert [segment] = result.summary["cadence_lock"]["segments"]
      assert_in_delta segment["start_distance_m"], 300 * 7.0, 7.0
      assert result.quality["cadence_lock_samples"] == locked(points)
      assert Enum.all?(result.summary["histogram"], &(&1["bpm"] >= 140))
    end

    test "brief mismatches do not break a lock, and its edges follow HR down to cadence" do
      # HR falls from 120 towards cadence, then tracks it with 1-2 s blips, like
      # the 2026-11-03 ride around km 2-3.
      approach = for hr <- 100..92//-1, do: {hr, 84}
      lock = for i <- 1..80, do: if(rem(i, 9) == 0, do: {84, 90}, else: {84, 83})
      points = ride([{120, 84} | approach] ++ lock ++ [{130, 0}])

      # The 80 s core, plus the approach sample within 8 bpm of cadence (92).
      assert locked(points) in 80..90
      refute HeartRate.cadence_lock?(hd(points))
    end

    test "coasting, short matches and unrelated HR are not a lock" do
      coasting = for _ <- 1..120, do: {80, 0}
      short = for _ <- 1..50, do: {85, 84}
      unrelated = for _ <- 1..300, do: {150, 85}

      assert locked(ride(coasting)) == 0
      assert locked(ride(short ++ unrelated)) == 0
      assert locked(ride(unrelated)) == 0
      assert HeartRate.analyze(ride(unrelated)).summary["cadence_lock"]["samples"] == 0
    end
  end
end
