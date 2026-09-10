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
end
