defmodule TrackAnalyzer.Tracks.HeartRate do
  @moduledoc """
  Time-weighted HR observations, independent of GPS validity. Integrals assume
  linear change between readings no more than 30 seconds apart in one segment.
  Abrupt transitions remain visible but cannot support comparison/drift windows.
  Durations are seconds; load is weighted zone-minutes, not TSS or fitness.
  """
  @durations [60, 300, 600, 1_200]
  @moving_threshold 2 / 3.6

  # Wrist optical sensors sometimes lock onto pedaling cadence and report it as
  # heart rate. A stretch where HR stays within @lock_tolerance_bpm of a non-zero
  # cadence for at least @lock_min_s is treated as locked. Mismatches of up to
  # @lock_max_break_s do not end it (per-second cadence is noisier than optical
  # HR). Once found, its edges extend while HR still follows cadence within
  # @lock_edge_tolerance_bpm. Locked samples keep their recorded value but are
  # left out of every HR statistic.
  @lock_tolerance_bpm 3
  @lock_min_s 60
  @lock_max_break_s 3
  @lock_edge_tolerance_bpm 8

  def normalize(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> normalize(number)
      _ -> nil
    end
  end

  def normalize(value) when is_number(value) and value >= 30 and value <= 240, do: value * 1.0
  def normalize(_), do: nil

  def prepare(points) do
    {points, _} =
      Enum.map_reduce(points, nil, fn point, previous ->
        hr = normalize(Map.get(point, :heart_rate_bpm) || point.extras["hr"])
        dt = seconds(previous, point)

        jump =
          previous != nil and same_segment?(previous, point) and is_number(dt) and dt > 0 and
            dt <= 10 and
            is_number(previous.heart_rate_bpm) and is_number(hr) and
            abs(hr - previous.heart_rate_bpm) > 30

        gap =
          previous == nil or not same_segment?(previous, point) or not is_number(dt) or dt <= 0 or
            dt > 30 or
            is_nil(Map.get(previous || %{}, :heart_rate_bpm)) or is_nil(hr)

        point =
          point
          |> Map.put(:heart_rate_bpm, hr)
          |> Map.update!(:extras, &(&1 |> Map.put("hr_jump", jump) |> Map.put("hr_break", gap)))

        {point, point}
      end)

    flag_cadence_lock(points)
  end

  @doc "True when this sample was flagged as cadence picked up by the HR sensor."
  def cadence_lock?(point), do: (Map.get(point, :extras) || %{})["hr_cadence_lock"] == true

  defp usable_hr?(point),
    do: is_number(Map.get(point, :heart_rate_bpm)) and not cadence_lock?(point)

  defp flag_cadence_lock(points) do
    samples = List.to_tuple(points)

    locked =
      samples
      |> lock_cores()
      |> Enum.map(fn {first, last} ->
        {extend_lock(samples, first, -1), extend_lock(samples, last, 1)}
      end)
      |> Enum.flat_map(fn {first, last} -> Enum.to_list(first..last) end)
      |> MapSet.new()

    if MapSet.size(locked) == 0 do
      points
    else
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        if MapSet.member?(locked, index),
          do: Map.update!(point, :extras, &Map.put(&1, "hr_cadence_lock", true)),
          else: point
      end)
    end
  end

  # Index ranges {first, last} of runs that match closely for long enough.
  defp lock_cores(samples) do
    {cores, run} =
      Enum.reduce(0..(tuple_size(samples) - 1)//1, {[], nil}, fn index, {cores, run} ->
        point = elem(samples, index)

        cond do
          (lock_match?(point, @lock_tolerance_bpm) and run) &&
              lock_continues?(elem(samples, elem(run, 1)), point, @lock_max_break_s + 1) ->
            {cores, {elem(run, 0), index}}

          lock_match?(point, @lock_tolerance_bpm) ->
            {close_core(samples, run, cores), {index, index}}

          run && pedaling?(point) &&
              lock_continues?(elem(samples, elem(run, 1)), point, @lock_max_break_s) ->
            {cores, run}

          true ->
            {close_core(samples, run, cores), nil}
        end
      end)

    samples |> close_core(run, cores) |> Enum.reverse()
  end

  defp close_core(_samples, nil, cores), do: cores

  defp close_core(samples, {first, last}, cores) do
    duration = seconds(elem(samples, first), elem(samples, last))
    if is_number(duration) and duration >= @lock_min_s, do: [{first, last} | cores], else: cores
  end

  # Walks outward from a core edge with the looser tolerance and the same bridging.
  defp extend_lock(samples, edge, step) do
    Stream.iterate(edge + step, &(&1 + step))
    |> Enum.reduce_while(edge, fn index, last_good ->
      if index < 0 or index >= tuple_size(samples) do
        {:halt, last_good}
      else
        point = elem(samples, index)
        anchor = elem(samples, last_good)
        {a, b} = if step < 0, do: {point, anchor}, else: {anchor, point}

        cond do
          lock_match?(point, @lock_edge_tolerance_bpm) and
              lock_continues?(a, b, @lock_max_break_s + 1) ->
            {:cont, index}

          pedaling?(point) and lock_continues?(a, b, @lock_max_break_s) ->
            {:cont, last_good}

          true ->
            {:halt, last_good}
        end
      end
    end)
  end

  defp lock_match?(point, tolerance) do
    pedaling?(point) and abs(point.heart_rate_bpm - point.cadence_rpm) <= tolerance
  end

  defp pedaling?(point) do
    cadence = Map.get(point, :cadence_rpm)
    is_number(cadence) and cadence > 0 and is_number(Map.get(point, :heart_rate_bpm))
  end

  defp lock_continues?(a, b, max_seconds) do
    dt = seconds(a, b)
    same_segment?(a, b) and is_number(dt) and dt > 0 and dt <= max_seconds
  end

  defp lock_summary(points, origin) do
    locked = Enum.filter(points, &cadence_lock?/1)

    segments =
      points
      |> Enum.chunk_by(&cadence_lock?/1)
      |> Enum.filter(&cadence_lock?(hd(&1)))
      |> Enum.map(fn run ->
        first = hd(run)
        last = List.last(run)

        %{
          "start_s" => offset(origin, first),
          "end_s" => offset(origin, last),
          "start_distance_m" => Map.get(first, :cumulative_distance_m),
          "end_distance_m" => Map.get(last, :cumulative_distance_m),
          "average_bpm" => average(run, :heart_rate_bpm),
          "average_rpm" => average(run, :cadence_rpm)
        }
      end)

    %{
      "samples" => length(locked),
      "seconds" =>
        Enum.reduce(segments, 0.0, fn s, total ->
          total + ((s["end_s"] || 0) - (s["start_s"] || 0))
        end),
      "segments" => segments
    }
  end

  defp average(points, field),
    do: Enum.reduce(points, 0.0, &(Map.fetch!(&1, field) + &2)) / length(points)

  def analyze(points, profile \\ %{}) do
    spans = intervals(points)
    valid = Enum.filter(points, &usable_hr?/1)
    peak = Enum.max_by(valid, & &1.heart_rate_bpm, fn -> nil end)
    total = elapsed(points)
    covered = sum(spans, :duration_s)
    moving = Enum.filter(spans, & &1.moving?)
    origin = first_time(points)

    jumps =
      points
      |> Enum.filter(&(&1.extras["hr_jump"] == true))
      |> Enum.map(fn p ->
        t = offset(origin, p) || 0

        %{
          "position" => p.position,
          "start_s" => max(t - (p.extras["delta_seconds"] || 0), 0),
          "end_s" => t,
          "bpm" => p.heart_rate_bpm
        }
      end)

    summary = %{
      "sample_count" => length(valid),
      "covered_s" => covered,
      "coverage_percent" => ratio(covered * 100, total),
      "moving_covered_s" => sum(moving, :duration_s),
      "average_bpm" => mean(spans),
      "moving_average_bpm" => mean(moving),
      "minimum_bpm" => valid |> Enum.map(& &1.heart_rate_bpm) |> minimum(),
      "maximum_bpm" => peak && peak.heart_rate_bpm,
      "peak_s" => if(peak, do: offset(origin, peak)),
      "peak_position" => peak && peak.position,
      "histogram" => histogram(spans),
      "duration_curve" => duration_curve(spans),
      "sectors" => sectors(spans, points),
      "drift" => drift(spans),
      "jumps" => jumps,
      "cadence_lock" => lock_summary(points, origin)
    }

    quality = %{
      "missing_samples" =>
        Enum.count(points, &(is_nil(&1.extras["hr"]) and is_nil(Map.get(&1, :heart_rate_bpm)))),
      "invalid_samples" =>
        Enum.count(
          points,
          &(not is_nil(&1.extras["hr"]) and is_nil(Map.get(&1, :heart_rate_bpm)))
        ),
      "suspect_transitions" => length(jumps),
      "cadence_lock_samples" => Enum.count(points, &cadence_lock?/1),
      "uncovered_s" => max(total - covered, 0)
    }

    %{summary: with_zones(summary, profile), quality: quality}
  end

  def intervals(points, origin \\ nil) do
    points |> timeline(origin) |> Enum.filter(& &1.hr?)
  end

  defp timeline(points, origin) do
    origin = origin || first_time(points)

    {spans, _} =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map_reduce(nil, fn [a, b], moving_since ->
        dt = seconds(a, b)
        time_ok = origin != nil and is_number(dt) and dt > 0 and dt <= 30 and same_segment?(a, b)
        speed = span_speed(b)
        moving = time_ok and is_number(speed) and speed >= @moving_threshold

        start = if(time_ok, do: DateTime.diff(a.recorded_at, origin, :millisecond) / 1000)
        moving_since = if moving, do: moving_since || start, else: nil

        hr_ok = time_ok and usable_hr?(a) and usable_hr?(b)

        span =
          if time_ok do
            %{
              start_s: start,
              end_s: DateTime.diff(b.recorded_at, origin, :millisecond) / 1000,
              duration_s: dt,
              h0: a.heart_rate_bpm,
              h1: b.heart_rate_bpm,
              hr?: hr_ok,
              area: if(hr_ok, do: (a.heart_rate_bpm + b.heart_rate_bpm) / 2 * dt),
              d0: Map.get(a, :cumulative_distance_m, 0.0),
              d1: Map.get(b, :cumulative_distance_m, 0.0),
              speed: speed,
              grade: Map.get(b, :grade_percent),
              moving?: moving,
              eligible?:
                hr_ok and moving and start >= 300 and start - moving_since >= 60 and
                  b.extras["hr_jump"] != true and a.extras["hr_jump"] != true,
              segment: segment_key(b)
            }
          end

        {span, moving_since}
      end)

    Enum.reject(spans, &is_nil/1)
  end

  # Wheel-sensor speed when recorded, else GPS speed between accepted fixes.
  defp span_speed(point) do
    sensor = Map.get(point, :sensor_speed_mps)

    cond do
      is_number(sensor) and sensor <= TrackAnalyzer.Tracks.Analyzer.max_plausible_speed_mps() ->
        sensor

      Map.get(point, :valid, true) ->
        Map.get(point, :derived_speed_mps)

      true ->
        nil
    end
  end

  def selection(points, origin, from, until) do
    timeline = points |> timeline(origin) |> clip(from, until)
    spans = Enum.filter(timeline, & &1.hr?)

    %{
      "start_s" => from,
      "end_s" => until,
      "duration_s" => until - from,
      "covered_s" => sum(spans, :duration_s),
      "average_bpm" => mean(spans),
      "maximum_bpm" => spans |> Enum.flat_map(&[&1.h0, &1.h1]) |> maximum(),
      "change_bpm" => if(spans != [], do: List.last(spans).h1 - hd(spans).h0),
      "distance_m" => Enum.reduce(timeline, 0.0, fn s, total -> total + max(s.d1 - s.d0, 0) end),
      "speed_kmh" => weighted_speed(Enum.filter(timeline, & &1.moving?)),
      "histogram" => histogram(spans)
    }
  end

  def with_zones(summary, profile) do
    edges = profile["edges"]
    revision = profile["revision"]

    if is_list(edges) and length(edges) == 5 and (summary["covered_s"] || 0) > 0 do
      # One-BPM integration bins allow recalibration without rereading GPX files.
      bins = summary["histogram"] || []

      zones =
        for {lower, index} <- Enum.with_index(edges) do
          upper = Enum.at(edges, index + 1, 241)

          seconds =
            bins
            |> Enum.filter(&(&1["bpm"] >= lower and &1["bpm"] < upper))
            |> Enum.reduce(0.0, &(&1["seconds"] + &2))

          %{
            "zone" => index + 1,
            "lower" => lower,
            "upper" => if(index < 4, do: upper),
            "seconds" => seconds
          }
        end

      Map.merge(summary, %{
        "zones" => zones,
        "load" => Enum.reduce(zones, 0.0, &(&1["seconds"] / 60 * &1["zone"] + &2)),
        "zone_revision" => revision
      })
    else
      Map.merge(summary, %{"zones" => [], "load" => nil, "zone_revision" => revision})
    end
  end

  def distribution(summary) do
    (summary["histogram"] || [])
    |> Enum.group_by(&(div(&1["bpm"], 10) * 10))
    |> Enum.sort()
    |> Enum.map(fn {bpm, rows} ->
      %{
        "label" => "#{bpm}–#{bpm + 9}",
        "bpm" => bpm,
        "seconds" => Enum.reduce(rows, 0.0, &(&1["seconds"] + &2))
      }
    end)
  end

  defp histogram(spans) do
    Enum.reduce(spans, %{}, fn span, bins ->
      low = min(span.h0, span.h1)
      high = max(span.h0, span.h1)

      Enum.reduce(floor(low)..floor(high), bins, fn bpm, acc ->
        seconds =
          if high == low,
            do: span.duration_s,
            else: span.duration_s * max(min(high, bpm + 1) - max(low, bpm), 0) / (high - low)

        Map.update(acc, bpm, seconds, &(&1 + seconds))
      end)
    end)
    |> Enum.sort()
    |> Enum.map(fn {bpm, seconds} -> %{"bpm" => bpm, "seconds" => seconds} end)
    |> Enum.filter(&(&1["seconds"] > 0))
  end

  defp duration_curve(spans) do
    runs = contiguous_runs(spans)

    for duration <- @durations do
      best =
        runs
        |> Enum.map(&best_window(&1, duration))
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(& &1["average_bpm"], fn -> nil end)

      best || %{"duration_s" => duration, "average_bpm" => nil, "start_s" => nil, "end_s" => nil}
    end
  end

  # Prefix integrals and binary search keep each duration O(n log n).
  defp best_window([], _), do: nil

  defp best_window(run, duration) do
    first = hd(run).start_s
    last = List.last(run).end_s

    if last - first >= duration do
      {rows, _} =
        Enum.map_reduce(run, 0.0, fn span, area ->
          {Map.put(span, :prefix, area), area + span.area}
        end)

      tuple = List.to_tuple(rows)

      boundaries =
        [first, last - duration | Enum.flat_map(run, &[&1.end_s, &1.end_s - duration])]
        |> Enum.filter(&(&1 >= first and &1 + duration <= last))
        |> Enum.uniq()
        |> Enum.sort()

      # Between boundaries the derivative of a rolling integral is linear.
      # Include its roots, so peaks between recorded timestamps are not missed.
      roots =
        boundaries
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.flat_map(fn [a, b] ->
          da = reading(tuple, a + duration) - reading(tuple, a)
          db = reading(tuple, b + duration) - reading(tuple, b)
          if da * db < 0, do: [a + (b - a) * da / (da - db)], else: []
        end)

      (boundaries ++ roots)
      |> Enum.map(fn start ->
        %{
          "duration_s" => duration,
          "start_s" => start,
          "end_s" => start + duration,
          "average_bpm" => (integral(tuple, start + duration) - integral(tuple, start)) / duration
        }
      end)
      |> Enum.max_by(& &1["average_bpm"])
    end
  end

  defp integral(tuple, time) do
    span = elem(tuple, search(tuple, time, 0, tuple_size(tuple) - 1))
    t = min(max(time - span.start_s, 0), span.duration_s)
    span.prefix + span.h0 * t + (span.h1 - span.h0) * t * t / (2 * span.duration_s)
  end

  defp reading(tuple, time) do
    span = elem(tuple, search(tuple, time, 0, tuple_size(tuple) - 1))
    interpolate(span.h0, span.h1, min(max((time - span.start_s) / span.duration_s, 0), 1))
  end

  defp search(_tuple, _time, lo, hi) when lo >= hi, do: lo

  defp search(tuple, time, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(tuple, mid).end_s < time,
      do: search(tuple, time, mid + 1, hi),
      else: search(tuple, time, lo, mid)
  end

  defp sectors(_spans, points) do
    total = points |> Enum.map(&Map.get(&1, :cumulative_distance_m, 0)) |> Enum.max(fn -> 0 end)

    if total > 0 do
      timeline(points, nil)
      |> Enum.filter(&(&1.moving? and &1.start_s >= 300))
      |> Enum.group_by(fn s -> min(floor((s.d0 + s.d1) / 2 / total * 64), 63) end)
      |> Enum.sort()
      |> Enum.map(fn {index, all} ->
        eligible = Enum.filter(all, & &1.eligible?)

        %{
          "index" => index,
          "moving_s" => sum(all, :duration_s),
          "eligible_s" => sum(eligible, :duration_s),
          "average_bpm" => mean(eligible),
          "speed_kmh" => weighted_speed(eligible),
          "start_s" => hd(all).start_s,
          "end_s" => List.last(all).end_s
        }
      end)
    else
      []
    end
  end

  defp drift(spans) do
    candidates =
      spans
      |> Enum.filter(& &1.eligible?)
      |> contiguous_runs()
      |> Enum.filter(&(sum(&1, :duration_s) >= 1800))

    candidates =
      Enum.filter(candidates, fn run ->
        duration = sum(run, :duration_s)
        avg = weighted_speed(run) / 3.6

        variance =
          Enum.reduce(run, 0.0, fn s, acc -> acc + (s.speed - avg) ** 2 * s.duration_s end) /
            duration

        flat_s =
          Enum.filter(run, &(is_number(&1.grade) and abs(&1.grade) <= 2)) |> sum(:duration_s)

        :math.sqrt(variance) / avg <= 0.15 and flat_s / duration >= 0.9
      end)

    case Enum.max_by(candidates, &sum(&1, :duration_s), fn -> nil end) do
      nil ->
        %{
          "available" => false,
          "reason" =>
            "Needs 30 continuous minutes after warm-up with steady speed, flat terrain, and usable HR."
        }

      run ->
        first = hd(run).start_s
        last = List.last(run).end_s
        middle = (first + last) / 2
        a = clip(run, first, middle)
        b = clip(run, middle, last)
        ratio_a = weighted_speed(a) / mean(a)
        ratio_b = weighted_speed(b) / mean(b)

        %{
          "available" => true,
          "percent" => (ratio_a - ratio_b) / ratio_a * 100,
          "start_s" => first,
          "end_s" => last,
          "first_bpm" => mean(a),
          "second_bpm" => mean(b)
        }
    end
  end

  defp contiguous_runs(spans) do
    spans
    |> Enum.reduce([], fn span, runs ->
      case runs do
        [[previous | _] = run | rest]
        when previous.end_s == span.start_s and previous.segment == span.segment ->
          [[span | run] | rest]

        _ ->
          [[span] | runs]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  defp clip(spans, from, until) do
    spans
    |> Enum.filter(&(&1.end_s > from and &1.start_s < until))
    |> Enum.map(fn s ->
      start = max(s.start_s, from)
      finish = min(s.end_s, until)
      f0 = (start - s.start_s) / s.duration_s
      f1 = (finish - s.start_s) / s.duration_s
      h0 = interpolate(s.h0, s.h1, f0)
      h1 = interpolate(s.h0, s.h1, f1)

      %{
        s
        | start_s: start,
          end_s: finish,
          duration_s: finish - start,
          h0: h0,
          h1: h1,
          area: if(s.hr?, do: (h0 + h1) / 2 * (finish - start)),
          d0: s.d0 + (s.d1 - s.d0) * f0,
          d1: s.d0 + (s.d1 - s.d0) * f1
      }
    end)
  end

  defp interpolate(a, b, fraction) when is_number(a) and is_number(b), do: a + (b - a) * fraction
  defp interpolate(_, _, _), do: nil

  defp weighted_speed([]), do: nil

  defp weighted_speed(spans),
    do: Enum.reduce(spans, 0.0, &(&1.speed * &1.duration_s + &2)) / sum(spans, :duration_s) * 3.6

  defp mean([]), do: nil
  defp mean(spans), do: sum(spans, :area) / sum(spans, :duration_s)
  defp sum(rows, field), do: Enum.reduce(rows, 0.0, &(Map.fetch!(&1, field) + &2))
  defp ratio(_, b) when b == 0, do: 0.0
  defp ratio(a, b), do: a / b
  defp minimum([]), do: nil
  defp minimum(values), do: Enum.min(values)
  defp maximum([]), do: nil
  defp maximum(values), do: Enum.max(values)

  defp first_time(points),
    do:
      points
      |> Enum.map(& &1.recorded_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

  defp elapsed(points) do
    times = points |> Enum.map(& &1.recorded_at) |> Enum.reject(&is_nil/1)

    if times == [],
      do: 0,
      else:
        DateTime.diff(Enum.max(times, DateTime), Enum.min(times, DateTime), :millisecond) / 1000
  end

  defp offset(origin, point) do
    if point.recorded_at && origin,
      do: DateTime.diff(point.recorded_at, origin, :millisecond) / 1000
  end

  defp seconds(nil, _), do: nil

  defp seconds(%{recorded_at: %DateTime{} = a}, %{recorded_at: %DateTime{} = b}),
    do: DateTime.diff(b, a, :millisecond) / 1000

  defp seconds(_, _), do: nil

  defp segment_key(point),
    do:
      Map.get(point, :track_segment_id) ||
        {Map.get(point, :track_position, 0), Map.get(point, :segment_position, 0)}

  defp same_segment?(a, b), do: segment_key(a) == segment_key(b)
end
