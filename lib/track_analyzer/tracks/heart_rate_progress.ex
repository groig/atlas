defmodule TrackAnalyzer.Tracks.HeartRateProgress do
  @moduledoc "Conservative, same-direction route observations; not a fitness estimate."
  import Ecto.Query
  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Tracks.{RouteCluster, RouteMatcher}

  def routes do
    RouteCluster
    |> order_by([c], desc: c.track_count)
    |> preload([:representative_track, memberships: [track: :renderings]])
    |> Repo.all()
    |> Enum.map(fn cluster ->
      %{id: cluster.id, name: cluster.name, signal: summarize(cluster)}
    end)
    |> Enum.filter(&(&1.signal.recorded_count > 0))
  end

  def summarize(cluster) do
    tracks = Enum.map(cluster.memberships, & &1.track)

    representative_id =
      Map.get(cluster, :representative_track_id) ||
        (cluster.representative_track && cluster.representative_track.id)

    representative = Enum.find(tracks, &(&1.id == representative_id)) || List.first(tracks)
    recorded = Enum.filter(tracks, &((&1.stats["heart_rate"]["sample_count"] || 0) > 0))

    attempts =
      with true <- not is_nil(representative),
           {:ok, feature} <- RouteMatcher.feature(representative) do
        recorded
        |> Enum.flat_map(fn track ->
          hr = track.stats["heart_rate"]

          with true <- (hr["coverage_percent"] || 0) >= 90,
               true <-
                 not is_nil(track.started_at) and
                   track.activity_type == representative.activity_type and
                   not is_nil(track.activity_type),
               true <- RouteMatcher.eligible?(track),
               {:ok, right} <- RouteMatcher.feature(track),
               {:ok, match} <- RouteMatcher.match(feature, right) do
            shift = match.metrics["alignment"]

            sectors =
              (hr["sectors"] || [])
              |> Enum.filter(&usable_sector?/1)
              |> Map.new(fn sector ->
                {Integer.mod(sector["index"] - shift, 64), sector}
              end)

            if map_size(sectors) > 0, do: [%{track: track, sectors: sectors}], else: []
          else
            _ -> []
          end
        end)
        |> Enum.sort_by(& &1.track.started_at, DateTime)
      else
        _ -> []
      end

    %{
      recorded_count: length(recorded),
      eligible_count: length(attempts),
      pair: compare(Enum.take(attempts, -2)),
      trend: trend(attempts)
    }
  end

  defp usable_sector?(s) do
    (s["moving_s"] || 0) > 0 and (s["eligible_s"] || 0) / s["moving_s"] >= 0.90 and
      is_number(s["average_bpm"]) and is_number(s["speed_kmh"])
  end

  # Public pure functions make the statistical gates testable independently of geometry.
  def compare([a, b]) do
    with {:ok, [left, right], indexes} <- matched_observations([a, b]) do
      observation(left, right, 5.0, 2.0)
      |> Map.merge(%{
        available: true,
        before_id: a.track.id,
        after_id: b.track.id,
        before_name: a.track.name,
        after_name: b.track.name,
        sector_count: length(indexes),
        before_start_s: left.start_s,
        before_end_s: left.end_s,
        after_start_s: right.start_s,
        after_end_s: right.end_s,
        support_s: min(left.duration_s, right.duration_s)
      })
    else
      _ ->
        unavailable(
          "Needs at least three minutes of shared route with 90% usable HR, after warm-up and stops."
        )
    end
  end

  def compare(_),
    do: unavailable("Record this route again in the same direction with HR to compare effort.")

  def trend(attempts) do
    recent = Enum.take(attempts, -6)

    with true <- length(recent) == 6,
         true <-
           DateTime.diff(List.last(recent).track.started_at, hd(recent).track.started_at, :second) >=
             14 * 86_400,
         {:ok, rows, indexes} <- matched_observations(recent) do
      {previous, latest} = Enum.split(rows, 3)
      a = center(previous)
      b = center(latest)
      hr_noise = max(5.0, 2 * max(mad(previous, :bpm), mad(latest, :bpm)))
      speed_noise = max(2.0, 200 * max(mad(previous, :speed), mad(latest, :speed)) / a.speed)

      observation(a, b, hr_noise, speed_noise)
      |> Map.merge(%{
        available: true,
        sector_count: length(indexes),
        attempts: 6,
        hr_noise: hr_noise,
        speed_noise: speed_noise
      })
    else
      _ ->
        unavailable(
          "A trend needs six comparable attempts across at least 14 days. Pair comparisons appear sooner."
        )
    end
  end

  defp matched_observations(attempts) do
    indexes =
      attempts
      |> Enum.map(&(Map.keys(&1.sectors) |> MapSet.new()))
      |> Enum.reduce(&MapSet.intersection/2)
      |> MapSet.to_list()
      |> Enum.sort()

    rows =
      Enum.map(attempts, fn attempt ->
        sectors = Enum.map(indexes, &Map.fetch!(attempt.sectors, &1))

        %{
          bpm: median(Enum.map(sectors, & &1["average_bpm"])),
          speed: median(Enum.map(sectors, & &1["speed_kmh"])),
          duration_s: Enum.reduce(sectors, 0.0, &(&1["eligible_s"] + &2)),
          start_s: sectors |> Enum.map(& &1["start_s"]) |> Enum.min(fn -> nil end),
          end_s: sectors |> Enum.map(& &1["end_s"]) |> Enum.max(fn -> nil end)
        }
      end)

    if indexes != [] and
         Enum.all?(rows, &(&1.duration_s >= 180 and is_number(&1.speed) and &1.speed > 0)),
       do: {:ok, rows, indexes},
       else: :insufficient
  end

  defp observation(a, b, hr_noise, speed_noise) do
    hr_delta = b.bpm - a.bpm
    speed_delta = (b.speed - a.speed) / a.speed * 100
    similar_speed = abs(speed_delta) <= 5
    similar_hr = abs(hr_delta) <= 5

    label =
      cond do
        similar_speed and hr_delta < -hr_noise -> "Lower HR at similar speed"
        similar_speed and hr_delta > hr_noise -> "Higher HR at similar speed"
        similar_hr and speed_delta > speed_noise -> "Faster at similar HR"
        similar_hr and speed_delta < -speed_noise -> "Slower at similar HR"
        similar_speed or similar_hr -> "No clear change"
        true -> "Different effort — not comparable"
      end

    %{
      label: label,
      before_bpm: a.bpm,
      after_bpm: b.bpm,
      before_speed: a.speed,
      after_speed: b.speed,
      hr_delta: hr_delta,
      speed_delta: speed_delta,
      similar_speed?: similar_speed,
      similar_hr?: similar_hr
    }
  end

  defp unavailable(reason), do: %{available: false, reason: reason}

  defp center(rows),
    do: %{bpm: median(Enum.map(rows, & &1.bpm)), speed: median(Enum.map(rows, & &1.speed))}

  defp mad(rows, key) do
    values = Enum.map(rows, &Map.fetch!(&1, key))
    middle = median(values)
    values |> Enum.map(&abs(&1 - middle)) |> median()
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    (Enum.at(sorted, div(count - 1, 2)) + Enum.at(sorted, div(count, 2))) / 2
  end
end
