defmodule TrackAnalyzer.Demo do
  @moduledoc """
  Creates a deterministic, wholly synthetic OsmAnd export for product demos.

  The route geometry is generated around central Copenhagen and is never derived
  from imported user data. Seeding is guarded to an isolated `_demo` database.
  """

  import Ecto.Query

  alias TrackAnalyzer.Imports
  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Storage.Local
  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.{GeoMetrics, Track}
  alias TrackAnalyzer.Workers.{AnalyzeTrackWorker, ArchiveWorker}

  @track_count 36
  @point_count 220
  @bounds %{min_lat: 55.60, max_lat: 55.75, min_lon: 12.45, max_lon: 12.70}
  @base_date ~U[2025-03-12 06:45:00.000Z]
  @route_names [
    "Harbor Circuit",
    "Lakes Tempo",
    "Amager Arc",
    "Citadel Loop",
    "Canal Lines",
    "Nordhavn Sweep"
  ]

  def track_count, do: @track_count

  def seed! do
    assert_safe_environment!()

    case Repo.aggregate(Track, :count, :id) do
      0 -> seed_archive!()
      @track_count -> assert_safe_dataset!()
      count -> raise "refusing demo seed: isolated database already contains #{count} tracks"
    end
  end

  def write_archive!(path, count \\ @track_count) when count in 1..@track_count do
    generated = for index <- 0..(count - 1), do: generated_track(index)

    manifest = %{
      "version" => 3,
      "items" =>
        Enum.map(generated, fn track ->
          %{
            "type" => "GPX",
            "subtype" => "gpx",
            "file" => "/#{track.path}",
            "total_distance" => track.distance_m,
            "time_span" => track.elapsed_ms,
            "show_arrows" => false,
            "show_start_finish" => true,
            "coloring_type" => "speed"
          }
        end)
    }

    entries =
      [{~c"items.json", Jason.encode!(manifest)}] ++
        Enum.map(generated, &{String.to_charlist(&1.path), &1.gpx})

    {:ok, {_name, binary}} = :zip.create(~c"synthetic_copenhagen.osf", entries, [:memory])
    File.write!(path, binary)
    path
  end

  def assert_safe_environment! do
    database = Repo.config() |> Keyword.fetch!(:database) |> to_string()
    storage_root = Local.root() |> Path.expand()

    unless String.ends_with?(database, "_demo") do
      raise "refusing demo seed: database must end in _demo (got #{database})"
    end

    unless storage_root |> Path.split() |> Enum.any?(&(&1 == "demo")) do
      raise "refusing demo seed: storage path must contain a demo path segment"
    end

    :ok
  end

  def assert_safe_dataset! do
    tracks = Repo.all(from track in Track, preload: [:renderings])

    unless length(tracks) == @track_count and Enum.all?(tracks, &safe_track?/1) do
      raise "privacy guard failed: screenshot database contains non-synthetic route data"
    end

    %{track_count: length(tracks), tracks: tracks}
  end

  defp seed_archive! do
    Local.ensure_directories()
    temporary_path = Path.join(Local.root(), "staging/synthetic_copenhagen.osf")

    try do
      write_archive!(temporary_path)
      {:ok, batch} = Imports.create_batch()
      {:ok, archive} = Imports.accept_archive(batch, temporary_path, "Synthetic_Copenhagen.osf")
      {:ok, _batch} = Imports.finish_upload(batch)

      :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})

      analysis_results =
        Tracks.list_tracks()
        |> Task.async_stream(
          fn track -> AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}}) end,
          max_concurrency: 4,
          timeout: :infinity,
          ordered: false
        )
        |> Enum.to_list()

      unless Enum.all?(analysis_results, &match?({:ok, :ok}, &1)) do
        raise "synthetic analysis failed: #{inspect(analysis_results)}"
      end

      assert_safe_dataset!()
    after
      _ = File.rm(temporary_path)
    end
  end

  defp safe_track?(track) do
    bounds = track.bounds || %{}

    track.status == "complete" and
      track.source_folder == "tracks/demo" and
      String.starts_with?(track.name, "DEMO · ") and
      within?(bounds["min_lat"], @bounds.min_lat, @bounds.max_lat) and
      within?(bounds["max_lat"], @bounds.min_lat, @bounds.max_lat) and
      within?(bounds["min_lon"], @bounds.min_lon, @bounds.max_lon) and
      within?(bounds["max_lon"], @bounds.min_lon, @bounds.max_lon)
  end

  defp within?(value, minimum, maximum),
    do: is_number(value) and value >= minimum and value <= maximum

  defp generated_track(index) do
    name = "DEMO · #{Enum.at(@route_names, rem(index, length(@route_names)))} #{index + 1}"
    started_at = DateTime.add(@base_date, index * 15, :day)
    coordinates = coordinates(index)
    points = timed_points(coordinates, started_at, index)
    path = "tracks/demo/#{String.pad_leading(Integer.to_string(index + 1), 2, "0")}_synthetic.gpx"
    elapsed_ms = DateTime.diff(List.last(points).time, started_at, :millisecond)

    %{
      path: path,
      distance_m: List.last(points).distance_m,
      elapsed_ms: elapsed_ms,
      gpx: gpx(name, points)
    }
  end

  defp coordinates(index) do
    center_lat = 55.6761 + (rem(index, 3) - 1) * 0.014
    center_lon = 12.5683 + (rem(div(index, 3), 3) - 1) * 0.021
    phase = rem(index, 6) * :math.pi() / 12

    for position <- 0..(@point_count - 1) do
      angle = 2 * :math.pi() * position / (@point_count - 1)
      shape = rem(index, 3)

      {lat_wave, lon_wave} =
        case shape do
          0 -> {:math.sin(angle), :math.cos(angle)}
          1 -> {:math.sin(angle), :math.sin(2 * angle) * 0.78}
          2 -> {:math.sin(angle) + 0.18 * :math.sin(3 * angle), :math.cos(angle)}
        end

      %{
        latitude: center_lat + 0.0072 * lat_wave,
        longitude: center_lon + 0.0115 * lon_wave,
        elevation_m: 18.0 + 12.0 * :math.sin(angle * 9 + phase) + rem(index, 4) * 1.5,
        position: position
      }
    end
  end

  defp timed_points([first | rest], started_at, index) do
    initial = Map.merge(first, %{time: started_at, distance_m: 0.0, speed_mps: nil, hdop: 2.1})

    {points, _previous, _time, _distance} =
      Enum.reduce(rest, {[initial], first, started_at, 0.0}, fn point,
                                                                {points, previous, time,
                                                                 distance_m} ->
        segment_distance = GeoMetrics.distance_m(previous, point)
        speed_mps = target_speed(index, point.position)
        interval_ms = max(round(segment_distance / speed_mps * 1_000), 1_000)
        time = DateTime.add(time, interval_ms, :millisecond)
        distance_m = distance_m + segment_distance

        hdop =
          if rem(index, 8) == 0 and point.position in 60..85,
            do: 12.5,
            else: 1.8 + rem(point.position + index, 5) * 0.18

        generated =
          Map.merge(point, %{
            time: time,
            distance_m: distance_m,
            speed_mps: speed_mps,
            hdop: hdop
          })

        {[generated | points], point, time, distance_m}
      end)

    Enum.reverse(points)
  end

  defp target_speed(index, position) do
    baseline = 5.35 + index * 0.055
    rhythm = 0.7 * :math.sin(position / 12 + index / 4)
    pulse = if position in 66..76, do: 3.0 + index * 0.035, else: 0.0
    isolated_peak = if rem(index, 8) == 4 and position == 46, do: 4.0, else: 0.0
    recovery = if position in 130..143, do: -1.4, else: 0.0
    max(baseline + rhythm + pulse + isolated_peak + recovery, 2.2)
  end

  defp gpx(name, points) do
    track_points = Enum.map_join(points, "\n", &gpx_point/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="Track Atlas synthetic demo" xmlns="http://www.topografix.com/GPX/1/1" xmlns:osmand="https://osmand.net">
      <metadata><name>#{name}</name></metadata>
      <trk><name>#{name}</name><trkseg>
    #{track_points}
      </trkseg></trk>
    </gpx>
    """
  end

  defp gpx_point(point) do
    latitude = :erlang.float_to_binary(point.latitude, decimals: 7)
    longitude = :erlang.float_to_binary(point.longitude, decimals: 7)
    elevation = :erlang.float_to_binary(point.elevation_m, decimals: 1)
    hdop = :erlang.float_to_binary(point.hdop, decimals: 1)

    speed =
      if point.speed_mps, do: :erlang.float_to_binary(point.speed_mps, decimals: 2), else: "0"

    "    <trkpt lat=\"#{latitude}\" lon=\"#{longitude}\"><ele>#{elevation}</ele><time>#{DateTime.to_iso8601(point.time)}</time><hdop>#{hdop}</hdop><extensions><osmand:speed>#{speed}</osmand:speed></extensions></trkpt>"
  end
end
