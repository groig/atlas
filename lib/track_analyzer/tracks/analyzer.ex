defmodule TrackAnalyzer.Tracks.Analyzer do
  @moduledoc """
  Deterministic, versioned cycling analysis over normalized GPX/FIT observations.
  """

  alias TrackAnalyzer.Tracks.{GeoMetrics, HeartRate, Sensors}

  @analysis_version 6
  @effort_distances [1_000, 5_000, 10_000, 20_000, 40_000]

  # Nobody rides faster than this. A step between two GPS fixes that implies a
  # higher speed is a position error, and so is a device speed above it.
  @max_plausible_speed_kmh 80
  @max_plausible_speed_mps @max_plausible_speed_kmh / 3.6

  # Receivers often log a stale or rough position until they get a good fix. An
  # implausible jump within this many seconds of a segment's start marks every
  # earlier point of that segment as pre-fix noise.
  @gps_warmup_s 60

  # When at least this share of points carries a device channel (wheel-sensor
  # speed or odometer distance), it replaces GPS for speed and distance.
  @sensor_coverage 0.9

  # Longer gaps between device readings are pauses, so speed is not integrated over them.
  @max_sensor_gap_s 30

  # Tracks below any of these are near-empty recordings and are skipped.
  @min_points 10
  @min_distance_m 200
  @min_moving_s 60

  def analysis_version, do: @analysis_version
  def max_plausible_speed_mps, do: @max_plausible_speed_mps

  def analyze(parsed, options \\ []) do
    config = Application.fetch_env!(:track_analyzer, :analysis)
    derived = derive_points(parsed.points, config)

    points =
      derived.points
      |> add_grades(config[:grade_window_m])
      |> HeartRate.prepare()
      |> Sensors.prepare()

    hr = HeartRate.analyze(points, Keyword.get(options, :heart_rate_profile, %{}))
    sensors = Sensors.analyze(points)
    timing_points = timing_points(points, derived.source)

    splits =
      kilometer_splits(timing_points, derived.cumulative_distance_m) ++
        best_efforts(timing_points)

    speed_metrics = speed_metrics(points, splits, derived.source)
    summary = summarize(parsed, points, derived, config, speed_metrics)

    summary =
      summary
      |> put_in([:stats, "heart_rate"], hr.summary)
      |> put_in([:quality, "heart_rate"], hr.quality)
      |> put_in([:stats, "cadence"], sensors.cadence)
      |> put_in([:stats, "speed_sensor"], sensors.speed_sensor)
      |> put_in([:quality, "sensors"], sensors.quality)

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

  # Two passes. The GPS pass decides which fixes are plausible and how far they
  # are apart; the credit pass decides what distance and moving time the track
  # is credited with, from the device's sensors when it has them, else from GPS.
  defp derive_points(points, config) do
    points =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, position} ->
        point
        |> Map.put(:position, position)
        |> Map.put_new(:sensor_speed_mps, nil)
        |> Map.put_new(:sensor_distance_m, nil)
      end)

    source = %{
      distance: distance_source(points),
      speed: if(covered?(points, :sensor_speed_mps), do: :sensor, else: :gps)
    }

    gps = gps_pass(points, warmup_positions(points), config)

    {points, credit} =
      Enum.map_reduce(gps.points, %{previous: nil, distance: 0.0, moving: 0.0}, fn point, acc ->
        {delta, seconds} = credit(acc.previous, point, source.distance)
        distance = acc.distance + delta

        moving =
          if is_number(seconds) and seconds > 0 and
               delta / seconds >= config[:moving_threshold_mps],
             do: seconds,
             else: 0.0

        point =
          point
          |> Map.put(:cumulative_distance_m, distance)
          |> Map.update!(:extras, fn extras ->
            extras
            |> Map.put("delta_seconds", seconds)
            |> Map.put("delta_distance_m", delta)
          end)

        {point, %{previous: point, distance: distance, moving: acc.moving + moving}}
      end)

    %{
      points: points,
      source: source,
      cumulative_distance_m: credit.distance,
      moving_s: credit.moving,
      elevation_gain_m: gps.gain,
      elevation_loss_m: gps.loss,
      invalid_count: gps.spikes + gps.warmup,
      spike_count: gps.spikes,
      warmup_count: gps.warmup
    }
  end

  defp distance_source(points) do
    cond do
      covered?(points, :sensor_distance_m) -> :odometer
      covered?(points, :sensor_speed_mps) -> :wheel_speed
      true -> :gps
    end
  end

  defp covered?([], _field), do: false

  defp covered?(points, field),
    do: Enum.count(points, &is_number(Map.get(&1, field))) / length(points) >= @sensor_coverage

  # Positions logged before the receiver settled: everything ahead of the last
  # implausible step that happens within the first seconds of a segment.
  defp warmup_positions(points) do
    points
    |> Enum.chunk_by(&{&1.track_position, &1.segment_position})
    |> Enum.flat_map(fn [first | _] = segment ->
      cut =
        segment
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [a, b] ->
          elapsed = seconds_between(first, b)

          is_number(elapsed) and elapsed <= @gps_warmup_s and
            not plausible_step?(step_speed(a, b))
        end)
        |> List.last()

      case cut do
        nil ->
          []

        [_a, b] ->
          segment |> Enum.take_while(&(&1.position < b.position)) |> Enum.map(& &1.position)
      end
    end)
    |> MapSet.new()
  end

  # Each fix is measured from the last accepted one (the anchor). An implausible
  # step is rejected, so a lone spike never moves the track. When the receiver
  # relocates for good, the fix after the rejected one is plausible relative to
  # it, and the track continues from there; the jump itself is never credited.
  defp gps_pass(points, warmup, config) do
    initial = %{anchor: nil, pending: nil, out: [], gain: 0.0, loss: 0.0, spikes: 0, warmup: 0}

    points
    |> Enum.reduce(initial, fn point, acc ->
      cond do
        MapSet.member?(warmup, point.position) ->
          point = gps_point(point, false, nil, 0.0, nil, %{"gps_warmup" => true})
          %{acc | out: [point | acc.out], warmup: acc.warmup + 1}

        not same_segment?(acc.anchor, point) ->
          point = gps_point(point, true, nil, 0.0, nil)
          %{acc | out: [point | acc.out], anchor: point, pending: nil}

        plausible_step?(step_speed(acc.anchor, point)) ->
          accept(acc, acc.anchor, point, config)

        acc.pending && plausible_step?(step_speed(acc.pending, point)) ->
          accept(acc, acc.pending, point, config)

        true ->
          point = gps_point(point, false, step_speed(acc.anchor, point), 0.0, nil)
          %{acc | out: [point | acc.out], pending: point, spikes: acc.spikes + 1}
      end
    end)
    |> then(fn acc -> acc |> Map.put(:points, Enum.reverse(acc.out)) |> Map.delete(:out) end)
  end

  defp accept(acc, from, point, config) do
    distance = GeoMetrics.distance_m(from, point)
    seconds = seconds_between(from, point)
    speed = if is_number(seconds) and seconds > 0, do: distance / seconds
    {gain, loss} = elevation_change(from, point, config[:elevation_noise_floor_m])
    point = gps_point(point, true, speed, distance, seconds)

    %{
      acc
      | out: [point | acc.out],
        anchor: point,
        pending: nil,
        gain: acc.gain + gain,
        loss: acc.loss + loss
    }
  end

  defp gps_point(point, valid?, speed, distance, seconds, extras \\ %{}) do
    point
    |> Map.put(:valid, valid?)
    |> Map.put(:derived_speed_mps, speed)
    |> Map.put(:grade_percent, nil)
    |> Map.put(
      :extras,
      point.extras |> Map.merge(extras) |> Map.put("gps_delta_distance_m", distance)
    )
    |> Map.put(:gps_delta_seconds, seconds)
  end

  defp step_speed(from, to) do
    seconds = seconds_between(from, to)
    if is_number(seconds) and seconds > 0, do: GeoMetrics.distance_m(from, to) / seconds
  end

  # Without a timestamp a step cannot be judged, so it is kept.
  defp plausible_step?(nil), do: true
  defp plausible_step?(speed), do: speed <= @max_plausible_speed_mps

  defp plausible_speed?(speed), do: is_number(speed) and speed <= @max_plausible_speed_mps

  # Distance and time credited to the span that ends at `point`.
  defp credit(_previous, point, :gps) do
    if point.valid,
      do: {point.extras["gps_delta_distance_m"], point.gps_delta_seconds},
      else: {0.0, nil}
  end

  defp credit(previous, point, _sensor) do
    seconds = if same_segment?(previous, point), do: seconds_between(previous, point)

    if is_number(seconds) and seconds > 0 do
      {sensor_delta(previous, point, seconds), seconds}
    else
      {0.0, nil}
    end
  end

  # The odometer first; a reset or a dropout falls back to wheel speed, then to
  # GPS when the previous fix was this one's anchor, so nothing is counted twice.
  defp sensor_delta(previous, point, seconds) do
    odometer =
      if is_number(previous.sensor_distance_m) and is_number(point.sensor_distance_m),
        do: point.sensor_distance_m - previous.sensor_distance_m

    cond do
      is_number(odometer) and odometer >= 0 and plausible_speed?(odometer / seconds) ->
        odometer

      plausible_speed?(point.sensor_speed_mps) and seconds <= @max_sensor_gap_s ->
        point.sensor_speed_mps * seconds

      point.valid and previous.valid and point.gps_delta_seconds == seconds ->
        point.extras["gps_delta_distance_m"]

      true ->
        0.0
    end
  end

  defp timing_points(points, %{distance: :gps}), do: Enum.filter(points, & &1.valid)
  defp timing_points(points, _sensor), do: points

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
    located = Enum.filter(points, & &1.valid)
    first = List.first(located)
    last = List.last(located)
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

    bounds = bounds(located)
    timezone = timezone(first)

    %{
      analysis_version: @analysis_version,
      name: parsed.name,
      creator: parsed.creator,
      activity_type: Map.get(parsed, :activity_type),
      point_count: point_count,
      segment_count: parsed.segments |> Enum.uniq() |> length(),
      distance_m: distance_m,
      elapsed_s: elapsed_s,
      moving_s: derived.moving_s,
      stopped_s: stopped_s,
      avg_speed_mps: if(derived.moving_s > 0, do: distance_m / derived.moving_s, else: nil),
      max_speed_mps: speed_metrics.max_speed_mps,
      best_1km_speed_mps: speed_metrics.best_1km_speed_mps,
      best_5km_speed_mps: speed_metrics.best_5km_speed_mps,
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
        "max_speed_confidence_reasons" => speed_metrics.confidence_reasons,
        "max_plausible_speed_mps" => @max_plausible_speed_mps,
        "distance_source" => Atom.to_string(derived.source.distance),
        "speed_source" => Atom.to_string(derived.source.speed)
      },
      quality: %{
        "invalid_spike_points" => derived.spike_count,
        "gps_warmup_points" => derived.warmup_count,
        "invalid_coordinate_points" => parsed.invalid_point_count,
        "records_without_position" => Map.get(parsed, :records_without_position, 0),
        "missing_time_points" => missing_time,
        "missing_elevation_points" => missing_elevation,
        "high_hdop_points" => high_hdop
      },
      skip_reason: skip_reason(point_count, distance_m, derived.moving_s)
    }
  end

  @doc """
  Why a track is too empty to count, or nil. Skipped tracks are kept and listed
  in the import log, but stay out of totals, records and recaps.
  """
  def skip_reason(point_count, distance_m, moving_s) do
    cond do
      point_count < @min_points ->
        "only #{point_count} #{if point_count == 1, do: "point", else: "points"}"

      (distance_m || 0) < @min_distance_m ->
        "only #{round(distance_m || 0)} m long"

      (moving_s || 0) < @min_moving_s ->
        "only #{round(moving_s || 0)} s of movement"

      true ->
        nil
    end
  end

  defp speed_metrics(points, splits, source) do
    candidates =
      Enum.filter(points, fn point ->
        speed = peak_speed(point, source.speed)
        is_number(speed) and speed > 0
      end)

    peak = Enum.max_by(candidates, &peak_speed(&1, source.speed), fn -> nil end)
    {confidence, reasons} = peak_confidence(points, peak, source.speed)

    %{
      max_speed_mps: if(peak, do: peak_speed(peak, source.speed)),
      max_speed_point_position: if(peak, do: peak.position),
      max_speed_confidence: confidence,
      best_1km_speed_mps: effort_speed(splits, 1_000),
      best_5km_speed_mps: effort_speed(splits, 5_000),
      speed_p95_mps: percentile(Enum.map(candidates, &peak_speed(&1, source.speed)), 0.95),
      confidence_reasons: reasons
    }
  end

  # With a wheel sensor, the peak is a sensor reading; GPS never competes with it.
  defp peak_speed(point, :sensor) do
    if plausible_speed?(point.sensor_speed_mps), do: point.sensor_speed_mps
  end

  # A position-derived peak the recorder's own speed does not confirm is the
  # tail of a GPS error (a displaced fix next to a rejected one), not a peak.
  defp peak_speed(point, :gps) do
    speed = gps_speed(point)
    if plausible_speed?(speed) and device_check(point) != :disagrees, do: speed
  end

  defp gps_speed(%{valid: true, derived_speed_mps: speed}) when is_number(speed), do: speed
  defp gps_speed(%{valid: true, recorded_speed_mps: speed}) when is_number(speed), do: speed
  defp gps_speed(_point), do: nil

  defp effort_speed(splits, distance) do
    case Enum.find(splits, &(&1.kind == "best_effort" and &1.position == distance)) do
      nil -> nil
      split -> split.avg_speed_mps
    end
  end

  defp peak_confidence(_points, nil, _source), do: {nil, []}

  # Wheel speed changes smoothly, so a real peak has a neighbour close to it.
  defp peak_confidence(points, peak, :sensor) do
    corroborated? =
      points
      |> neighbours(peak)
      |> Enum.any?(
        &(plausible_speed?(&1.sensor_speed_mps) and
            &1.sensor_speed_mps >= peak.sensor_speed_mps * 0.8)
      )

    if corroborated?,
      do: {"high", []},
      else: {"medium", ["no adjacent wheel-sensor reading within 80% of the peak"]}
  end

  defp peak_confidence(points, peak, :gps) do
    interval = peak.gps_delta_seconds
    timing_ok? = is_number(interval) and interval >= 1 and interval <= 15
    hdop_ok? = is_nil(peak.hdop) or peak.hdop <= 10
    device = device_check(peak)
    corroborated? = device == :agrees or corroborated_peak?(points, peak)

    confidence =
      cond do
        device == :disagrees -> "low"
        timing_ok? and hdop_ok? and corroborated? -> "high"
        timing_ok? and hdop_ok? -> "medium"
        true -> "low"
      end

    reasons =
      []
      |> maybe_reason(timing_ok?, "sample interval outside 1–15 seconds")
      |> maybe_reason(hdop_ok?, "HDOP above 10")
      |> maybe_reason(corroborated?, "no adjacent sample within 80% of the peak")
      |> maybe_reason(
        device != :disagrees,
        "device speed was #{device_speed_kmh(peak)} km/h at this point"
      )

    {confidence, reasons}
  end

  # A recorder's own speed (a wheel sensor, or the GPS Doppler speed OsmAnd
  # writes) is an independent check on a speed derived from positions, which a
  # single misplaced fix can inflate.
  defp device_check(peak) do
    case {device_speed(peak), gps_speed(peak)} do
      {device, gps} when is_number(device) and is_number(gps) ->
        if device >= gps * 0.8, do: :agrees, else: :disagrees

      _missing ->
        :unavailable
    end
  end

  defp device_speed(%{sensor_speed_mps: speed}) when is_number(speed), do: speed

  defp device_speed(%{derived_speed_mps: derived, recorded_speed_mps: speed})
       when is_number(derived) and is_number(speed),
       do: speed

  defp device_speed(_point), do: nil

  defp device_speed_kmh(peak) do
    case device_speed(peak) do
      device when is_number(device) -> :erlang.float_to_binary(device * 3.6, decimals: 1)
      _missing -> "—"
    end
  end

  defp corroborated_peak?(points, peak) do
    points
    |> neighbours(peak)
    |> Enum.any?(fn point ->
      speed = gps_speed(point)
      is_number(speed) and speed >= gps_speed(peak) * 0.8
    end)
  end

  # Points carry their list index as position, so neighbours are direct lookups.
  defp neighbours(points, point) do
    [point.position - 1, point.position + 1]
    |> Enum.filter(&(&1 >= 0))
    |> Enum.map(&Enum.at(points, &1))
    |> Enum.filter(&(&1 && same_segment?(&1, point)))
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
          "speed_kmh" => Enum.map(sampled, &round_or_nil(kmh(speed_or_nil(&1)), 1)),
          "grade_percent" => Enum.map(sampled, &round_or_nil(&1.grade_percent, 1)),
          "heart_rate_bpm" => Enum.map(sampled, & &1.heart_rate_bpm),
          "hr_jump" => Enum.map(sampled, & &1.extras["hr_jump"]),
          "hr_break" => Enum.map(sampled, & &1.extras["hr_break"]),
          "cadence_rpm" => Enum.map(sampled, &round_or_nil(&1.cadence_rpm, 0)),
          "sensor_speed_kmh" =>
            Enum.map(
              sampled,
              &if(&1.sensor_speed_mps, do: round_to(&1.sensor_speed_mps * 3.6, 1))
            ),
          "position" => Enum.map(sampled, & &1.position),
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

  defp speed_for(point), do: speed_or_nil(point) || 0.0

  # The device's own speed when it is plausible, else the speed between
  # accepted fixes. A rejected fix has no speed at all.
  defp speed_or_nil(point) do
    if plausible_speed?(point.sensor_speed_mps),
      do: point.sensor_speed_mps,
      else: gps_speed(point)
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
    count = length(points)
    step = max(ceil(count / maximum), 1)
    # A sampled line must not silently interpolate across an omitted HR gap.
    # Mark each retained endpoint if any intervening observation breaks continuity.
    {sampled, _} =
      points
      |> Enum.with_index()
      |> Enum.map_reduce({false, false}, fn {point, index}, {gap, jump} ->
        gap = gap or point.extras["hr_break"] == true
        jump = jump or point.extras["hr_jump"] == true

        if rem(index, step) == 0 or index == count - 1 do
          kept = %{
            point
            | extras: point.extras |> Map.put("hr_break", gap) |> Map.put("hr_jump", jump)
          }

          {kept, {false, false}}
        else
          {nil, {gap, jump}}
        end
      end)

    sampled = Enum.reject(sampled, &is_nil/1)
    last = List.last(points)
    if List.last(sampled).position == last.position, do: sampled, else: sampled ++ [last]
  end

  defp average(points, field),
    do: Enum.sum(Enum.map(points, &Map.fetch!(&1, field))) / length(points)

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)
  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp kmh(nil), do: nil
  defp kmh(mps), do: mps * 3.6

  defp round_or_nil(nil, _precision), do: nil
  defp round_or_nil(number, precision), do: round_to(number, precision)
  defp round_to(number, precision), do: Float.round(number * 1.0, precision)
end
