defmodule TrackAnalyzer.Tracks.RouteMatcher do
  @moduledoc """
  Deterministic route similarity for completed tracks.

  Routes are compared at equal-distance samples. The deliberately conservative
  thresholds favor repeatable journeys over visually nearby routes.
  """

  alias TrackAnalyzer.Tracks.{GeoMetrics, Rendering, Track}

  @sample_count 64
  @minimum_distance_m 500.0
  @minimum_quality 70.0
  @minimum_distance_ratio 0.90
  @maximum_endpoint_distance_m 250.0
  @maximum_median_distance_m 120.0
  @maximum_p90_distance_m 250.0
  @loop_score 0.95
  @matcher_version 1

  def matcher_version, do: @matcher_version

  def eligible?(%Track{} = track) do
    track.status == "complete" and not is_nil(track.started_at) and
      number_at_least?(track.distance_m, @minimum_distance_m) and
      number_at_least?(track.moving_s, 1.0) and
      number_at_least?(track.quality_score, @minimum_quality) and
      not is_nil(overview(track))
  end

  def feature(%Track{} = track) do
    with %Rendering{} = rendering <- overview(track),
         coordinates when length(coordinates) >= 2 <- decode(rendering.encoded_polyline),
         samples when length(samples) == @sample_count <- resample(coordinates, @sample_count) do
      {:ok,
       %{
         track: track,
         samples: samples,
         distance_m: track.distance_m,
         avg_speed_mps: track.avg_speed_mps,
         activity_type: present(track.activity_type),
         loop?: loop?(track),
         direction: direction(samples)
       }}
    else
      _missing -> {:error, :insufficient_geometry}
    end
  end

  def match(left, right) do
    with :ok <- compatible_activity(left, right),
         distance_ratio when distance_ratio >= @minimum_distance_ratio <-
           ratio(left.distance_m, right.distance_m),
         {:ok, distances, alignment} <- paired_distances(left, right),
         median when median <= @maximum_median_distance_m <- median(distances),
         p90 when p90 <= @maximum_p90_distance_m <- percentile(distances, 0.90) do
      distance_score = distance_ratio
      median_score = max(0.0, 1.0 - median / @maximum_median_distance_m)
      p90_score = max(0.0, 1.0 - p90 / @maximum_p90_distance_m)
      similarity = 0.40 * distance_score + 0.35 * median_score + 0.25 * p90_score

      {:ok,
       %{
         similarity: similarity,
         metrics: %{
           "distance_ratio" => distance_ratio,
           "median_distance_m" => median,
           "p90_distance_m" => p90,
           "alignment" => alignment
         }
       }}
    else
      _not_a_match -> :no_match
    end
  end

  def fingerprint(feature) do
    feature.samples
    |> Enum.map(fn point ->
      "#{Float.round(point.latitude, 3)},#{Float.round(point.longitude, 3)}"
    end)
    |> Enum.join(";")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def decode(encoded_polyline) when is_binary(encoded_polyline) do
    Enum.map(Polyline.decode(encoded_polyline), fn {longitude, latitude} ->
      %{latitude: latitude, longitude: longitude}
    end)
  end

  def resample(coordinates, count) when length(coordinates) >= 2 and count >= 2 do
    cumulative = cumulative_distances(coordinates)
    total = cumulative |> List.last() |> elem(0)

    if total <= 0 do
      []
    else
      for index <- 0..(count - 1) do
        target = total * index / (count - 1)
        interpolate_at(cumulative, target)
      end
    end
  end

  def resample(_coordinates, _count), do: []

  defp overview(%Track{renderings: renderings}) when is_list(renderings),
    do: Enum.find(renderings, &(&1.level == "overview"))

  defp overview(_track), do: nil

  defp cumulative_distances([first | rest]) do
    {_previous, _distance, cumulative} =
      Enum.reduce(rest, {first, 0.0, [{0.0, first}]}, fn point,
                                                         {previous, distance, cumulative} ->
        distance = distance + GeoMetrics.distance_m(previous, point)
        {point, distance, [{distance, point} | cumulative]}
      end)

    Enum.reverse(cumulative)
  end

  defp interpolate_at(cumulative, target) do
    {left_distance, left, right_distance, right} = interval(cumulative, target)

    fraction =
      if right_distance > left_distance,
        do: (target - left_distance) / (right_distance - left_distance),
        else: 0.0

    %{
      latitude: left.latitude + (right.latitude - left.latitude) * fraction,
      longitude: left.longitude + (right.longitude - left.longitude) * fraction
    }
  end

  defp interval([only], _target) do
    {distance, point} = only
    {distance, point, distance, point}
  end

  defp interval([{left_distance, left}, {right_distance, right} | rest], target) do
    if target <= right_distance do
      {left_distance, left, right_distance, right}
    else
      interval([{right_distance, right} | rest], target)
    end
  end

  defp paired_distances(%{loop?: false} = left, %{loop?: false} = right) do
    endpoints_ok? =
      GeoMetrics.distance_m(List.first(left.samples), List.first(right.samples)) <=
        @maximum_endpoint_distance_m and
        GeoMetrics.distance_m(List.last(left.samples), List.last(right.samples)) <=
          @maximum_endpoint_distance_m

    if endpoints_ok?,
      do: {:ok, distances(left.samples, right.samples), 0},
      else: :no_match
  end

  defp paired_distances(
         %{loop?: true, direction: direction} = left,
         %{
           loop?: true,
           direction: direction
         } = right
       ) do
    0..(@sample_count - 1)
    |> Enum.map(fn shift ->
      shifted = rotate(right.samples, shift)
      route_distances = distances(left.samples, shifted)
      {median(route_distances), percentile(route_distances, 0.90), route_distances, shift}
    end)
    |> Enum.min_by(fn {median, p90, _distances, shift} -> {median, p90, shift} end)
    |> then(fn {_median, _p90, route_distances, shift} ->
      {:ok, route_distances, shift}
    end)
  end

  defp paired_distances(_left, _right), do: :no_match

  defp compatible_activity(%{activity_type: activity}, %{activity_type: activity})
       when not is_nil(activity),
       do: :ok

  defp compatible_activity(%{activity_type: left}, %{activity_type: right})
       when not is_nil(left) and not is_nil(right),
       do: :no_match

  defp compatible_activity(left, right) do
    speed_ratio = ratio(left.avg_speed_mps, right.avg_speed_mps)
    if speed_ratio >= 0.5, do: :ok, else: :no_match
  end

  defp distances(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.map(fn {left_point, right_point} ->
      GeoMetrics.distance_m(left_point, right_point)
    end)
  end

  defp rotate(values, 0), do: values
  defp rotate(values, shift), do: Enum.drop(values, shift) ++ Enum.take(values, shift)

  defp direction(samples) do
    area =
      samples
      |> Enum.zip(tl(samples) ++ [hd(samples)])
      |> Enum.reduce(0.0, fn {left, right}, acc ->
        acc + left.longitude * right.latitude - right.longitude * left.latitude
      end)

    if area >= 0, do: :counterclockwise, else: :clockwise
  end

  defp loop?(track) do
    score = get_in(track.stats || %{}, ["loop_score"])
    is_number(score) and score >= @loop_score
  end

  defp ratio(left, right) when is_number(left) and is_number(right) and left > 0 and right > 0,
    do: min(left, right) / max(left, right)

  defp ratio(_left, _right), do: 0.0

  defp median(values), do: percentile(values, 0.50)

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * percentile) - 1, 0)
    Enum.at(sorted, index)
  end

  defp number_at_least?(value, minimum), do: is_number(value) and value >= minimum
  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
