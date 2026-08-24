defmodule TrackAnalyzer.Tracks.Analyzer do
  @moduledoc """
  Deterministic, versioned cycling analysis over normalized GPX observations.
  """

  alias TrackAnalyzer.Tracks.GeoMetrics

  @analysis_version 2
  @effort_distances [100, 500, 1_000, 5_000, 10_000, 20_000, 40_000]

  def analysis_version, do: @analysis_version

  def analyze(parsed) do
    config = Application.fetch_env!(:track_analyzer, :analysis)
    derived = derive_points(parsed.points, config)
    points = add_grades(derived.points, config[:grade_window_m])
    splits = kilometer_splits(points, derived.cumulative_distance_m) ++ best_efforts(points)
    speed_metrics = speed_metrics(points, splits, config)
    summary = summarize(parsed, points, derived, config, speed_metrics)

    %{
      points: points,
      segments: summarize_segments(parsed.segments, points),
      summary: summary,
      events: stop_events(points, config) ++ climb_events(points),
      splits: splits,
      renderings: renderings(points),
      cells: route_cells(points)
    }
  end

  defp derive_points(points, config) do
    initial = %{
      points: [],
      previous_valid: nil,
      cumulative_distance_m: 0.0,
      moving_s: 0.0,
      elevation_gain_m: 0.0,
      elevation_loss_m: 0.0,
      invalid_count: 0
    }

    points
    |> Enum.with_index()
    |> Enum.reduce(initial, fn {point, position}, acc ->
      same_segment? = same_segment?(acc.previous_valid, point)
      distance = if same_segment?, do: GeoMetrics.distance_m(acc.previous_valid, point), else: 0.0
      delta_seconds = if same_segment?, do: seconds_between(acc.previous_valid, point), else: nil
      speed = if delta_seconds && delta_seconds > 0, do: distance / delta_seconds

      valid? =
        is_nil(speed) or speed <= config[:max_plausible_speed_mps]

      accepted_distance = if valid?, do: distance, else: 0.0
      cumulative_distance = acc.cumulative_distance_m + accepted_distance

      moving_seconds =
        if (valid? and speed) && speed >= config[:moving_threshold_mps],
          do: delta_seconds,
          else: 0.0

      {gain, loss} =
        if valid? and same_segment? do
          elevation_change(acc.previous_valid, point, config[:elevation_noise_floor_m])
        else
          {0.0, 0.0}
        end

      extras =
        point.extras
        |> Map.put("delta_seconds", delta_seconds)
        |> Map.put("delta_distance_m", accepted_distance)

      derived_point =
        point
        |> Map.put(:position, position)
        |> Map.put(:derived_speed_mps, speed)
        |> Map.put(:cumulative_distance_m, cumulative_distance)
        |> Map.put(:valid, valid?)
        |> Map.put(:grade_percent, nil)
        |> Map.put(:extras, extras)

      %{
        acc
        | points: [derived_point | acc.points],
          previous_valid: if(valid?, do: point, else: acc.previous_valid),
          cumulative_distance_m: cumulative_distance,
          moving_s: acc.moving_s + moving_seconds,
          elevation_gain_m: acc.elevation_gain_m + gain,
          elevation_loss_m: acc.elevation_loss_m + loss,
          invalid_count: acc.invalid_count + if(valid?, do: 0, else: 1)
      }
    end)
    |> Map.update!(:points, &Enum.reverse/1)
  end

  defp add_grades(points, window_m) do
    {graded, _prior} =
      Enum.reduce(points, {[], []}, fn point, {result, prior} ->
        reference =
          Enum.find(prior, fn candidate ->
            same_segment?(candidate, point) and
              point.cumulative_distance_m - candidate.cumulative_distance_m >= window_m
          end)

        grade =
          with %{elevation_m: elevation} when is_number(elevation) <- point,
               %{elevation_m: reference_elevation} when is_number(reference_elevation) <-
                 reference,
               distance when distance > 0 <-
                 point.cumulative_distance_m - reference.cumulative_distance_m do
            ((elevation - reference_elevation) / distance * 100)
            |> max(-40.0)
            |> min(40.0)
          else
            _missing -> nil
          end

        point = %{point | grade_percent: grade}
        {[point | result], [point | prior]}
      end)

    Enum.reverse(graded)
  end

  defp summarize(parsed, points, derived, config, speed_metrics) do
    first = List.first(points)
    last = List.last(points)
    times = points |> Enum.map(& &1.recorded_at) |> Enum.reject(&is_nil/1)
    elevations = points |> Enum.map(& &1.elevation_m) |> Enum.reject(&is_nil/1)
    started_at = Enum.min(times, DateTime, fn -> nil end)
    ended_at = Enum.max(times, DateTime, fn -> nil end)

    elapsed_s =
      if started_at && ended_at, do: DateTime.diff(ended_at, started_at, :millisecond) / 1000

    stopped_s = if elapsed_s, do: max(elapsed_s - derived.moving_s, 0.0)
    distance_m = derived.cumulative_distance_m

    displacement_m =
      if first && last, do: GeoMetrics.distance_m(first, last), else: 0.0

    missing_time = Enum.count(points, &is_nil(&1.recorded_at))
    missing_elevation = Enum.count(points, &is_nil(&1.elevation_m))
    high_hdop = Enum.count(points, &(is_number(&1.hdop) and &1.hdop > 10))
    point_count = length(points)

    quality_score =
      100.0
      |> subtract_ratio(derived.invalid_count, point_count, 40)
      |> subtract_ratio(missing_time, point_count, 30)
      |> subtract_ratio(missing_elevation, point_count, 15)
      |> subtract_ratio(high_hdop, point_count, 15)
      |> max(0.0)

    bounds = bounds(points)
    timezone = timezone(first)

    %{
      analysis_version: @analysis_version,
      name: parsed.name,
      creator: parsed.creator,
      point_count: point_count,
      segment_count: parsed.segments |> Enum.uniq() |> length(),
      distance_m: distance_m,
      elapsed_s: elapsed_s,
      moving_s: derived.moving_s,
      stopped_s: stopped_s,
      avg_speed_mps: if(derived.moving_s > 0, do: distance_m / derived.moving_s, else: nil),
      max_speed_mps: speed_metrics.max_speed_mps,
      best_100m_speed_mps: speed_metrics.best_100m_speed_mps,
      best_500m_speed_mps: speed_metrics.best_500m_speed_mps,
      max_speed_confidence: speed_metrics.max_speed_confidence,
      max_speed_point_position: speed_metrics.max_speed_point_position,
      elevation_gain_m: derived.elevation_gain_m,
      elevation_loss_m: derived.elevation_loss_m,
      min_elevation_m: min_or_nil(elevations),
      max_elevation_m: max_or_nil(elevations),
      quality_score: quality_score,
      started_at: started_at,
      ended_at: ended_at,
      timezone: timezone,
      bounds: bounds,
      stats: %{
        "displacement_m" => displacement_m,
        "loop_score" => loop_score(displacement_m, distance_m),
        "sinuosity" => if(displacement_m > 50, do: distance_m / displacement_m, else: nil),
        "dominant_bearing_degrees" =>
          if(first && last, do: GeoMetrics.bearing_degrees(first, last)),
        "recorded_speed_coverage" => coverage(points, :recorded_speed_mps),
        "elevation_coverage" => coverage(points, :elevation_m),
        "median_sample_seconds" => median_sample_seconds(points),
        "moving_threshold_mps" => config[:moving_threshold_mps],
        "speed_p95_mps" => speed_metrics.speed_p95_mps,
        "max_speed_confidence_reasons" => speed_metrics.confidence_reasons
      },
      quality: %{
        "invalid_spike_points" => derived.invalid_count,
        "invalid_coordinate_points" => parsed.invalid_point_count,
        "missing_time_points" => missing_time,
        "missing_elevation_points" => missing_elevation,
        "high_hdop_points" => high_hdop
      }
    }
  end

  defp speed_metrics(points, splits, config) do
    valid_speed_points =
      points
      |> Enum.filter(fn point ->
        point.valid and speed_for(point) > 0 and
          speed_for(point) <= config[:max_plausible_speed_mps]
      end)

    peak = Enum.max_by(valid_speed_points, &speed_for/1, fn -> nil end)
    {confidence, reasons} = peak_confidence(points, peak)

    %{
      max_speed_mps: if(peak, do: speed_for(peak)),
      max_speed_point_position: if(peak, do: peak.position),
      max_speed_confidence: confidence,
      best_100m_speed_mps: effort_speed(splits, 100),
      best_500m_speed_mps: effort_speed(splits, 500),
      speed_p95_mps: percentile(Enum.map(valid_speed_points, &speed_for/1), 0.95),
      confidence_reasons: reasons
    }
  end

  defp effort_speed(splits, distance) do
    case Enum.find(splits, &(&1.kind == "best_effort" and &1.position == distance)) do
      nil -> nil
      split -> split.avg_speed_mps
    end
  end

  defp peak_confidence(_points, nil), do: {nil, []}

  defp peak_confidence(points, peak) do
    interval = Map.get(peak.extras, "delta_seconds")
    timing_ok? = is_number(interval) and interval >= 1 and interval <= 15
    hdop_ok? = is_nil(peak.hdop) or peak.hdop <= 10
    corroborated? = corroborated_peak?(points, peak)

    confidence =
      cond do
        timing_ok? and hdop_ok? and corroborated? -> "high"
        timing_ok? and hdop_ok? -> "medium"
        true -> "low"
      end

    reasons =
      []
      |> maybe_reason(timing_ok?, "sample interval outside 1–15 seconds")
      |> maybe_reason(hdop_ok?, "HDOP above 10")
      |> maybe_reason(corroborated?, "no adjacent sample within 80% of the peak")

    {confidence, reasons}
  end

  defp corroborated_peak?(points, peak) do
    points
    |> Enum.filter(fn point ->
      same_segment?(point, peak) and abs(point.position - peak.position) == 1 and point.valid
    end)
    |> Enum.any?(&(speed_for(&1) >= speed_for(peak) * 0.8))
  end

  defp maybe_reason(reasons, true, _reason), do: reasons
  defp maybe_reason(reasons, false, reason), do: reasons ++ [reason]

  defp percentile([], _percentile), do: nil

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * percentile) - 1, 0)
    Enum.at(sorted, index)
  end

  defp summarize_segments(segments, points) do
    points_by_segment = Enum.group_by(points, &{&1.track_position, &1.segment_position})

    Enum.map(segments, fn segment ->
      segment_points = Map.get(points_by_segment, {segment.track_position, segment.position}, [])

      %{
        track_position: segment.track_position,
        position: segment.position,
        point_count: length(segment_points),
        started_at:
          segment_points |> Enum.map(& &1.recorded_at) |> Enum.reject(&is_nil/1) |> min_or_nil(),
        ended_at:
          segment_points |> Enum.map(& &1.recorded_at) |> Enum.reject(&is_nil/1) |> max_or_nil(),
        distance_m:
          segment_points
          |> Enum.map(&Map.get(&1.extras, "delta_distance_m", 0.0))
          |> Enum.sum(),
        stats: %{}
      }
    end)
  end

  defp stop_events(points, config) do
    {events, current} =
      Enum.reduce(points, {[], nil}, fn point, {events, current} ->
        seconds = Map.get(point.extras, "delta_seconds")

        stopped? =
          is_number(seconds) and seconds > 0 and speed_for(point) < config[:moving_threshold_mps]

        cond do
          stopped? and current ->
            {events,
             %{
               current
               | end_point_position: point.position,
                 end_distance_m: point.cumulative_distance_m,
                 duration_s: current.duration_s + seconds
             }}

          stopped? ->
            {events,
             %{
               kind: "stop",
               start_point_position: point.position,
               end_point_position: point.position,
               start_distance_m: point.cumulative_distance_m,
               end_distance_m: point.cumulative_distance_m,
               duration_s: seconds,
               metrics: %{}
             }}

          current ->
            {[current | events], nil}

          true ->
            {events, nil}
        end
      end)

    [current | events]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.duration_s >= config[:stop_minimum_seconds]))
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {event, position} -> Map.put(event, :position, position) end)
  end

  defp climb_events(points) do
    {events, current} =
      Enum.reduce(points, {[], nil}, fn point, {events, current} ->
        climbing? = is_number(point.grade_percent) and point.grade_percent >= 2.0

        cond do
          climbing? and current ->
            gain =
              max(
                (point.elevation_m || current.start_elevation_m) - current.start_elevation_m,
                0.0
              )

            {events,
             %{
               current
               | end_point_position: point.position,
                 end_distance_m: point.cumulative_distance_m,
                 gain_m: max(current.gain_m, gain),
                 max_grade: max(current.max_grade, point.grade_percent)
             }}

          climbing? and is_number(point.elevation_m) ->
            {events,
             %{
               kind: "climb",
               start_point_position: point.position,
               end_point_position: point.position,
               start_distance_m: point.cumulative_distance_m,
               end_distance_m: point.cumulative_distance_m,
               start_elevation_m: point.elevation_m,
               gain_m: 0.0,
               max_grade: point.grade_percent
             }}

          current ->
            {[current | events], nil}

          true ->
            {events, nil}
        end
      end)

    [current | events]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn climb ->
      climb.end_distance_m - climb.start_distance_m >= 300 and climb.gain_m >= 20
    end)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {climb, position} ->
      distance = climb.end_distance_m - climb.start_distance_m

      %{
        kind: "climb",
        position: position,
        start_point_position: climb.start_point_position,
        end_point_position: climb.end_point_position,
        start_distance_m: climb.start_distance_m,
        end_distance_m: climb.end_distance_m,
        duration_s: nil,
        metrics: %{
          "gain_m" => climb.gain_m,
          "distance_m" => distance,
          "average_grade" => if(distance > 0, do: climb.gain_m / distance * 100),
          "max_grade" => climb.max_grade
        }
      }
    end)
  end

  defp kilometer_splits(_points, distance_m) when distance_m < 1_000, do: []

  defp kilometer_splits(points, distance_m) do
    1..trunc(distance_m / 1_000)
    |> Enum.map(fn position ->
      end_distance = position * 1_000.0
      start_distance = end_distance - 1_000.0
      start_point = Enum.find(points, &(&1.cumulative_distance_m >= start_distance))
      end_point = Enum.find(points, &(&1.cumulative_distance_m >= end_distance))
      duration = duration_between(start_point, end_point)

      %{
        kind: "kilometer",
        position: position,
        start_distance_m: start_distance,
        end_distance_m: end_distance,
        duration_s: duration,
        distance_m: 1_000.0,
        avg_speed_mps: if(duration && duration > 0, do: 1_000.0 / duration),
        elevation_gain_m: positive_elevation(points, start_distance, end_distance),
        metrics: %{}
      }
    end)
  end

  defp best_efforts(points) do
    segment_point_sets =
      points
      |> Enum.chunk_by(&{&1.track_position, &1.segment_position})
      |> Enum.map(&List.to_tuple/1)

    Enum.flat_map(@effort_distances, fn target_distance ->
      best =
        segment_point_sets
        |> Enum.map(fn segment_points ->
          fastest_window(segment_points, tuple_size(segment_points), target_distance)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.min_by(&elem(&1, 0), fn -> nil end)

      case best do
        nil ->
          []

        {duration, start_point, end_point} ->
          [
            %{
              kind: "best_effort",
              position: target_distance,
              start_distance_m: start_point.cumulative_distance_m,
              end_distance_m: end_point.cumulative_distance_m,
              duration_s: duration,
              distance_m: target_distance * 1.0,
              avg_speed_mps: target_distance / duration,
              elevation_gain_m:
                positive_elevation(
                  points,
                  start_point.cumulative_distance_m,
                  end_point.cumulative_distance_m
                ),
              metrics: %{"target_distance_m" => target_distance}
            }
          ]
      end
    end)
  end

  defp fastest_window(_points, point_count, _target_distance) when point_count < 2, do: nil

  defp fastest_window(points, point_count, target_distance) do
    {_end_index, best} =
      Enum.reduce(0..(point_count - 2), {1, nil}, fn start_index, {end_index, best} ->
        start_point = elem(points, start_index)
        end_index = max(end_index, start_index + 1)

        end_index =
          advance_to_distance(points, point_count, start_point, end_index, target_distance)

        if end_index < point_count do
          end_point = elem(points, end_index)

          case duration_between(start_point, end_point) do
            duration when is_number(duration) and duration > 0 ->
              candidate = {duration, start_point, end_point}
              best = if is_nil(best) or duration < elem(best, 0), do: candidate, else: best
              {end_index, best}

            _missing ->
              {end_index, best}
          end
        else
          {end_index, best}
        end
      end)

    best
  end

  defp advance_to_distance(points, point_count, start_point, end_index, target_distance) do
    cond do
      end_index >= point_count ->
        point_count

      elem(points, end_index).cumulative_distance_m - start_point.cumulative_distance_m >=
          target_distance ->
        end_index

      true ->
        advance_to_distance(points, point_count, start_point, end_index + 1, target_distance)
    end
  end

  defp renderings(points) do
    [{"overview", 600}, {"detail", 2_500}]
    |> Enum.map(fn {level, maximum} ->
      sampled = sample(points, maximum)

      %{
        level: level,
        point_count: length(sampled),
        encoded_polyline:
          sampled
          |> Enum.map(&{&1.longitude, &1.latitude})
          |> Polyline.encode(),
        series: %{
          "distance_km" => Enum.map(sampled, &round_to(&1.cumulative_distance_m / 1_000, 3)),
          "elevation_m" => Enum.map(sampled, &round_or_nil(&1.elevation_m, 1)),
          "speed_kmh" => Enum.map(sampled, &round_or_nil(speed_for(&1) * 3.6, 1)),
          "grade_percent" => Enum.map(sampled, &round_or_nil(&1.grade_percent, 1)),
          "time" =>
            Enum.map(sampled, &if(&1.recorded_at, do: DateTime.to_iso8601(&1.recorded_at)))
        }
      }
    end)
  end

  defp route_cells(points) do
    points
    |> Enum.filter(& &1.valid)
    |> Enum.group_by(&Geohash.encode(&1.latitude, &1.longitude, 7))
    |> Enum.map(fn {cell, cell_points} ->
      %{
        precision: 7,
        cell: cell,
        latitude: average(cell_points, :latitude),
        longitude: average(cell_points, :longitude),
        point_count: length(cell_points)
      }
    end)
  end

  defp bounds([]), do: %{}

  defp bounds(points) do
    %{
      "min_lat" => points |> Enum.map(& &1.latitude) |> Enum.min(),
      "max_lat" => points |> Enum.map(& &1.latitude) |> Enum.max(),
      "min_lon" => points |> Enum.map(& &1.longitude) |> Enum.min(),
      "max_lon" => points |> Enum.map(& &1.longitude) |> Enum.max()
    }
  end

  defp timezone(_point), do: nil

  defp same_segment?(nil, _point), do: false

  defp same_segment?(left, right) do
    left.track_position == right.track_position and
      left.segment_position == right.segment_position
  end

  defp seconds_between(%{recorded_at: %DateTime{} = left}, %{recorded_at: %DateTime{} = right}) do
    DateTime.diff(right, left, :millisecond) / 1_000
  end

  defp seconds_between(_left, _right), do: nil

  defp duration_between(%{recorded_at: %DateTime{} = left}, %{recorded_at: %DateTime{} = right}) do
    duration = DateTime.diff(right, left, :millisecond) / 1_000
    if duration >= 0, do: duration
  end

  defp duration_between(_left, _right), do: nil

  defp elevation_change(%{elevation_m: left}, %{elevation_m: right}, floor)
       when is_number(left) and is_number(right) do
    change = right - left

    cond do
      change >= floor -> {change, 0.0}
      change <= -floor -> {0.0, abs(change)}
      true -> {0.0, 0.0}
    end
  end

  defp elevation_change(_left, _right, _floor), do: {0.0, 0.0}

  defp speed_for(point) do
    cond do
      is_number(point.derived_speed_mps) -> point.derived_speed_mps
      is_number(point.recorded_speed_mps) -> point.recorded_speed_mps
      true -> 0.0
    end
  end

  defp positive_elevation(points, start_distance, end_distance) do
    points
    |> Enum.filter(
      &(&1.cumulative_distance_m >= start_distance and &1.cumulative_distance_m <= end_distance)
    )
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [left, right], gain ->
      change =
        if is_number(left.elevation_m) and is_number(right.elevation_m),
          do: right.elevation_m - left.elevation_m,
          else: 0.0

      gain + max(change, 0.0)
    end)
  end

  defp median_sample_seconds(points) do
    intervals =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> seconds_between(left, right) end)
      |> Enum.filter(&(is_number(&1) and &1 > 0))
      |> Enum.sort()

    case intervals do
      [] -> nil
      values -> Enum.at(values, div(length(values), 2))
    end
  end

  defp coverage([], _field), do: 0.0

  defp coverage(points, field) do
    Enum.count(points, &(not is_nil(Map.get(&1, field)))) / length(points)
  end

  defp subtract_ratio(score, _count, 0, _weight), do: score
  defp subtract_ratio(score, count, total, weight), do: score - count / total * weight

  defp loop_score(_displacement, distance) when distance <= 0, do: 0.0
  defp loop_score(displacement, distance), do: max(0.0, 1.0 - min(displacement / distance, 1.0))

  defp sample(points, maximum) when length(points) <= maximum, do: points

  defp sample(points, maximum) do
    step = max(ceil(length(points) / maximum), 1)
    sampled = points |> Enum.take_every(step)
    last = List.last(points)
    if List.last(sampled) == last, do: sampled, else: sampled ++ [last]
  end

  defp average(points, field),
    do: Enum.sum(Enum.map(points, &Map.fetch!(&1, field))) / length(points)

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)
  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp round_or_nil(nil, _precision), do: nil
  defp round_or_nil(number, precision), do: round_to(number, precision)
  defp round_to(number, precision), do: Float.round(number * 1.0, precision)
end
