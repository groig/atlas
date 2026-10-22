defmodule TrackAnalyzer.Tracks.Sensors do
  @moduledoc """
  Cadence and speed-sensor analytics for one track.

  Readings describe the interval that ends at their timestamp (how 1 Hz FIT
  records and GPX extensions are written), so each span between two points uses
  the later point's value. Spans longer than 30 seconds or crossing a segment
  boundary are gaps and are never filled.

  "Device speed" is the speed the recorder wrote: a wheel sensor when one was
  paired, otherwise the device's own GPS. It is compared against the speed this
  app derives from positions, which is what every other view uses.
  """

  @max_cadence 250
  @max_speed_mps 150 / 3.6
  @max_distance_m 10_000_000
  @max_gap_s 30
  @moving_threshold_mps 2 / 3.6
  @coasting_below_rpm 1
  @development_bin_m 0.25
  @terrain [
    {"descent", "Descents", nil, -2.0},
    {"flat", "Flat", -2.0, 2.0},
    {"rolling", "Gentle climbs", 2.0, 5.0},
    {"climb", "Steep climbs", 5.0, nil}
  ]

  def normalize_cadence(value) when is_binary(value), do: value |> parse() |> normalize_cadence()

  def normalize_cadence(value) when is_number(value) and value >= 0 and value <= @max_cadence,
    do: value * 1.0

  def normalize_cadence(_value), do: nil

  def normalize_speed(value) when is_binary(value), do: value |> parse() |> normalize_speed()

  def normalize_speed(value) when is_number(value) and value >= 0 and value <= @max_speed_mps,
    do: value * 1.0

  def normalize_speed(_value), do: nil

  def normalize_distance(value) when is_number(value) and value >= 0 and value < @max_distance_m,
    do: value * 1.0

  def normalize_distance(_value), do: nil

  @doc "Ensures every point carries the sensor keys, so persistence never has to guess."
  def prepare(points) do
    Enum.map(points, fn point ->
      point
      |> Map.put_new(:cadence_rpm, nil)
      |> Map.put_new(:sensor_speed_mps, nil)
      |> Map.put_new(:sensor_distance_m, nil)
    end)
  end

  def analyze(points) do
    spans = spans(points)
    elapsed = elapsed(points)

    %{
      cadence: cadence_summary(points, spans, elapsed),
      speed_sensor: speed_summary(points, spans, elapsed),
      quality: quality(points)
    }
  end

  # -- Cadence ---------------------------------------------------------------

  defp cadence_summary(points, spans, elapsed) do
    readings = points |> Enum.map(& &1.cadence_rpm) |> Enum.filter(&is_number/1)

    if readings == [] do
      %{"sample_count" => 0}
    else
      with_cadence = Enum.filter(spans, &is_number(&1.cadence))
      moving = Enum.filter(with_cadence, & &1.moving?)
      pedaling = Enum.filter(moving, &(&1.cadence >= @coasting_below_rpm))
      coasting_s = sum(moving, :duration_s) - sum(pedaling, :duration_s)
      covered_s = sum(with_cadence, :duration_s)

      %{
        "sample_count" => length(readings),
        "covered_s" => covered_s,
        "coverage_percent" => ratio(covered_s * 100, elapsed),
        "moving_s" => sum(moving, :duration_s),
        "pedaling_s" => sum(pedaling, :duration_s),
        "coasting_s" => coasting_s,
        "coasting_percent" => ratio(coasting_s * 100, sum(moving, :duration_s)),
        "average_rpm" => weighted(pedaling, :cadence),
        "moving_average_rpm" => weighted(moving, :cadence),
        "maximum_rpm" => Enum.max(readings),
        "revolutions" => Enum.reduce(with_cadence, 0.0, &(&1.cadence * &1.duration_s / 60 + &2)),
        "histogram" => cadence_histogram(pedaling),
        "terrain" => terrain(moving),
        "development" => development(pedaling),
        "development_mode_m" => development_mode(pedaling)
      }
    end
  end

  defp cadence_histogram(pedaling) do
    pedaling
    |> Enum.group_by(&(trunc(&1.cadence / 10) * 10))
    |> Enum.sort()
    |> Enum.map(fn {rpm, spans} ->
      %{
        "rpm" => rpm,
        "seconds" => sum(spans, :duration_s),
        "speed_kmh" => kmh(weighted(Enum.filter(spans, &is_number(&1.speed)), :speed))
      }
    end)
  end

  defp terrain(moving) do
    graded = Enum.filter(moving, &is_number(&1.grade))

    for {key, label, low, high} <- @terrain do
      spans =
        Enum.filter(graded, fn span ->
          (is_nil(low) or span.grade >= low) and (is_nil(high) or span.grade < high)
        end)

      pedaling = Enum.filter(spans, &(&1.cadence >= @coasting_below_rpm))
      total = sum(spans, :duration_s)

      %{
        "band" => key,
        "label" => label,
        "seconds" => total,
        "average_rpm" => weighted(pedaling, :cadence),
        "coasting_percent" =>
          if(total > 0, do: (total - sum(pedaling, :duration_s)) / total * 100),
        "speed_kmh" => kmh(weighted(Enum.filter(spans, &is_number(&1.speed)), :speed))
      }
    end
  end

  # Metres travelled per crank revolution. Each gear combination is one value,
  # so peaks in this histogram reveal the gears actually ridden.
  defp development(pedaling) do
    pedaling
    |> development_spans()
    |> Enum.group_by(&(Float.floor(&1.development / @development_bin_m) * @development_bin_m))
    |> Enum.sort()
    |> Enum.map(fn {meters, spans} ->
      %{"meters" => Float.round(meters, 2), "seconds" => sum(spans, :duration_s)}
    end)
  end

  defp development_mode(pedaling) do
    case pedaling |> development() |> Enum.max_by(& &1["seconds"], fn -> nil end) do
      nil -> nil
      bin -> bin["meters"] + @development_bin_m / 2
    end
  end

  defp development_spans(pedaling) do
    pedaling
    |> Enum.filter(&(&1.cadence >= 30 and is_number(&1.speed) and &1.speed >= 2.0))
    |> Enum.map(&Map.put(&1, :development, &1.speed * 60 / &1.cadence))
    |> Enum.filter(&(&1.development >= 1.0 and &1.development <= 12.0))
  end

  # -- Speed sensor ----------------------------------------------------------

  defp speed_summary(points, spans, elapsed) do
    readings = points |> Enum.map(& &1.sensor_speed_mps) |> Enum.filter(&is_number/1)

    if readings == [] do
      %{"sample_count" => 0}
    else
      with_speed = Enum.filter(spans, &is_number(&1.device_speed))
      moving = Enum.filter(with_speed, &(&1.device_speed >= @moving_threshold_mps))
      covered_s = sum(with_speed, :duration_s)
      {device_m, gps_m, source} = comparable_distance(with_speed)
      comparable? = gps_m >= 1_000 and device_m > 0
      compared = Enum.filter(moving, &(is_number(&1.gps_speed) and &1.gps_speed > 0))
      differences = Enum.map(compared, &(abs(&1.device_speed - &1.gps_speed) * 3.6))

      within =
        Enum.count(compared, &(abs(&1.device_speed - &1.gps_speed) <= 0.1 * &1.gps_speed))

      %{
        "sample_count" => length(readings),
        "covered_s" => covered_s,
        "coverage_percent" => ratio(covered_s * 100, elapsed),
        "moving_s" => sum(moving, :duration_s),
        "average_moving_kmh" => kmh(weighted(moving, :device_speed)),
        "maximum_kmh" => kmh(Enum.max(readings)),
        "distance_m" => device_m,
        "distance_source" => source,
        "gps_distance_m" => gps_m,
        "distance_difference_percent" => if(comparable?, do: (device_m - gps_m) / gps_m * 100),
        "calibration_factor" => if(comparable?, do: gps_m / device_m),
        "compared_s" => sum(compared, :duration_s),
        "median_difference_kmh" => median(differences),
        "within_10_percent" => ratio(within * 100, length(compared)),
        "gps_gap_s" =>
          with_speed
          |> Enum.filter(&(not &1.gps_valid? and &1.device_speed >= @moving_threshold_mps))
          |> sum(:duration_s)
      }
    end
  end

  # Device distance comes from the recorder's own odometer when it wrote one,
  # otherwise from integrating device speed. Only spans that also have a GPS
  # distance are compared, so partial coverage does not skew the difference.
  defp comparable_distance(spans) do
    odometer = Enum.filter(spans, &is_number(&1.device_distance))

    if length(odometer) >= length(spans) * 0.9 and odometer != [] do
      device_m = Enum.reduce(odometer, 0.0, &(&1.device_distance + &2))
      {device_m, sum(odometer, :gps_distance), "device"}
    else
      device_m =
        Enum.reduce(spans, 0.0, fn span, total ->
          total + (span.previous_device_speed || span.device_speed) / 2 * span.duration_s +
            span.device_speed / 2 * span.duration_s
        end)

      {device_m, sum(spans, :gps_distance), "integrated"}
    end
  end

  # -- Shared ----------------------------------------------------------------

  defp spans(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      dt = seconds(a, b)

      if same_segment?(a, b) and is_number(dt) and dt > 0 and dt <= @max_gap_s do
        gps_valid? = Map.get(b, :valid, true) and is_number(Map.get(b, :derived_speed_mps))
        gps_speed = if gps_valid?, do: b.derived_speed_mps
        device_speed = Map.get(b, :sensor_speed_mps)
        speed = device_speed || gps_speed

        [
          %{
            duration_s: dt,
            cadence: Map.get(b, :cadence_rpm),
            device_speed: device_speed,
            previous_device_speed: Map.get(a, :sensor_speed_mps),
            device_distance: distance_delta(a, b),
            gps_speed: gps_speed,
            gps_valid?: gps_valid?,
            gps_distance: get_in(b, [:extras, "delta_distance_m"]) || 0.0,
            speed: speed,
            grade: Map.get(b, :grade_percent),
            moving?: is_number(speed) and speed >= @moving_threshold_mps
          }
        ]
      else
        []
      end
    end)
  end

  # Odometers reset when a recording restarts; a drop is a reset, not negative travel.
  defp distance_delta(a, b) do
    with left when is_number(left) <- Map.get(a, :sensor_distance_m),
         right when is_number(right) <- Map.get(b, :sensor_distance_m),
         delta when delta >= 0 <- right - left do
      delta
    else
      _missing -> nil
    end
  end

  defp quality(points) do
    raw_cadence = Enum.filter(points, &(not is_nil(raw_cadence(&1))))

    %{
      "cadence_invalid_samples" => Enum.count(raw_cadence, &is_nil(&1.cadence_rpm)),
      "cadence_missing_samples" =>
        Enum.count(points, &(is_nil(raw_cadence(&1)) and is_nil(&1.cadence_rpm)))
    }
  end

  defp raw_cadence(point) do
    extras = Map.get(point, :extras, %{})
    extras["cadence"] || extras["cad"] || extras["bike_cadence"]
  end

  defp weighted([], _field), do: nil

  defp weighted(spans, field) do
    total = sum(spans, :duration_s)

    if total > 0,
      do: Enum.reduce(spans, 0.0, &(Map.fetch!(&1, field) * &1.duration_s + &2)) / total
  end

  defp sum(rows, field), do: Enum.reduce(rows, 0.0, &(Map.fetch!(&1, field) + &2))
  defp ratio(_value, total) when total == 0, do: nil
  defp ratio(value, total), do: value / total
  defp kmh(nil), do: nil
  defp kmh(mps), do: mps * 3.6

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp elapsed(points) do
    times = points |> Enum.map(& &1.recorded_at) |> Enum.reject(&is_nil/1)

    if times == [],
      do: 0,
      else:
        DateTime.diff(Enum.max(times, DateTime), Enum.min(times, DateTime), :millisecond) / 1000
  end

  defp seconds(%{recorded_at: %DateTime{} = a}, %{recorded_at: %DateTime{} = b}),
    do: DateTime.diff(b, a, :millisecond) / 1000

  defp seconds(_a, _b), do: nil

  defp same_segment?(a, b) do
    Map.get(a, :track_position) == Map.get(b, :track_position) and
      Map.get(a, :segment_position) == Map.get(b, :segment_position)
  end

  defp parse(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _invalid -> nil
    end
  end
end
