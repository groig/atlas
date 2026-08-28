defmodule TrackAnalyzer.Tracks do
  @moduledoc """
  Query and persistence boundary for analyzed tracks.
  """

  import Ecto.Query

  alias TrackAnalyzer.Repo

  alias TrackAnalyzer.Tracks.{
    AnalysisEvent,
    Analyzer,
    Point,
    Rendering,
    RouteCell,
    Segment,
    Split,
    Track
  }

  @topic "tracks"
  @processing_statuses ~w(queued parsing cleaning analyzing indexing)

  def subscribe do
    Phoenix.PubSub.subscribe(TrackAnalyzer.PubSub, @topic)
  end

  def subscribe(track_id) do
    Phoenix.PubSub.subscribe(TrackAnalyzer.PubSub, topic(track_id))
  end

  def list_tracks(filters \\ %{}) do
    Track
    |> apply_status_filter(Map.get(filters, "status", "all"))
    |> apply_search(Map.get(filters, "q", ""))
    |> order_by([track], desc_nulls_last: track.started_at, desc: track.inserted_at)
    |> limit(500)
    |> Repo.all()
  end

  def get_track!(id) do
    Track
    |> Repo.get!(id)
    |> Repo.preload([:renderings, :events, :splits, :segments])
  end

  def get_track(id), do: Repo.get(Track, id)

  def compare_tracks(ids) do
    ids = Enum.take(ids, 4)

    Track
    |> where([track], track.id in ^ids and track.status in ["complete", "insufficient_data"])
    |> preload([:renderings])
    |> Repo.all()
    |> Enum.sort_by(&Enum.find_index(ids, fn id -> id == &1.id end))
  end

  def latest_complete_track do
    Track
    |> where([track], track.status == "complete")
    |> order_by([track], desc_nulls_last: track.started_at, desc: track.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def portfolio_summary do
    tracks = Repo.all(from track in Track, where: track.status == "complete")

    %{
      track_count: length(tracks),
      distance_m: sum(tracks, :distance_m),
      moving_s: sum(tracks, :moving_s),
      elevation_gain_m: sum(tracks, :elevation_gain_m),
      point_count: Enum.sum(Enum.map(tracks, & &1.point_count)),
      earliest_at: tracks |> Enum.map(& &1.started_at) |> Enum.reject(&is_nil/1) |> min_or_nil(),
      latest_at: tracks |> Enum.map(& &1.ended_at) |> Enum.reject(&is_nil/1) |> max_or_nil(),
      processing_count:
        Repo.aggregate(
          from(track in Track, where: track.status in ^@processing_statuses),
          :count,
          :id
        ),
      unique_route_cells: Repo.aggregate(RouteCell, :count, :id),
      quality_score: average(tracks, :quality_score),
      monthly: monthly_totals(tracks)
    }
  end

  def share_summary(:all) do
    Track
    |> where([track], track.status == "complete")
    |> Repo.all()
    |> build_share_summary()
  end

  def share_summary(%{from: %DateTime{} = from, until: %DateTime{} = until}) do
    Track
    |> where(
      [track],
      track.status == "complete" and track.started_at >= ^from and track.started_at < ^until
    )
    |> Repo.all()
    |> build_share_summary()
  end

  def heatmap_cells(limit \\ 8_000) do
    RouteCell
    |> group_by([cell], [cell.cell, cell.latitude, cell.longitude])
    |> select([cell], %{
      cell: cell.cell,
      latitude: cell.latitude,
      longitude: cell.longitude,
      weight: sum(cell.point_count),
      visits: count(cell.track_id)
    })
    |> order_by([cell], desc: sum(cell.point_count))
    |> limit(^limit)
    |> Repo.all()
  end

  def speed_history(filters \\ %{}) do
    metric = speed_metric(Map.get(filters, "metric", "100m"))
    range = speed_range(Map.get(filters, "range", "all"))

    all_tracks =
      Track
      |> where([track], track.status == "complete" and not is_nil(track.started_at))
      |> order_by([track], asc: track.started_at)
      |> Repo.all()

    visible_tracks = filter_speed_range(all_tracks, range)
    history = build_speed_history(visible_tracks, metric)

    %{
      metric: speed_metric_name(metric),
      range: range,
      points: history,
      records: %{
        instantaneous: speed_record(all_tracks, :max_speed_mps),
        best_100m: speed_record(all_tracks, :best_100m_speed_mps),
        best_500m: speed_record(all_tracks, :best_500m_speed_mps)
      },
      leaders: speed_leaders(visible_tracks, metric),
      recent_delta_percent: recent_speed_delta(history)
    }
  end

  def enqueue_stale_analyses do
    track_ids =
      Track
      |> where([track], track.analysis_version < ^Analyzer.analysis_version())
      |> select([track], track.id)
      |> Repo.all()

    inserted =
      Enum.count(track_ids, fn track_id ->
        case %{track_id: track_id, force: true}
             |> TrackAnalyzer.Workers.AnalyzeTrackWorker.new()
             |> Oban.insert() do
          {:ok, _job} -> true
          {:error, _changeset} -> false
        end
      end)

    {:ok, %{stale_count: length(track_ids), enqueued_count: inserted}}
  end

  def stale_analysis_count do
    Repo.aggregate(
      from(track in Track, where: track.analysis_version < ^Analyzer.analysis_version()),
      :count,
      :id
    )
  end

  def update_status(%Track{} = track, attrs) do
    track
    |> Track.changeset(attrs)
    |> Repo.update()
    |> broadcast_result()
  end

  def persist_analysis(%Track{} = track, result) do
    Repo.transaction(fn ->
      clear_analysis(track.id)
      segment_ids = insert_segments(track.id, result.segments)
      insert_points(track.id, segment_ids, result.points)
      insert_rows(AnalysisEvent, track.id, result.events)
      insert_rows(Split, track.id, result.splits)
      insert_rows(Rendering, track.id, result.renderings)
      insert_rows(RouteCell, track.id, result.cells)

      summary = result.summary
      status = if summary.point_count < 2, do: "insufficient_data", else: "complete"

      attrs = %{
        status: status,
        stage: if(status == "complete", do: "Ready to explore", else: "Not enough track points"),
        progress: 100,
        analysis_version: Analyzer.analysis_version(),
        name: summary.name || track.name,
        creator: summary.creator,
        activity_type: summary.activity_type,
        timezone: summary.timezone,
        started_at: summary.started_at,
        ended_at: summary.ended_at,
        point_count: summary.point_count,
        segment_count: summary.segment_count,
        distance_m: summary.distance_m,
        elapsed_s: summary.elapsed_s,
        moving_s: summary.moving_s,
        stopped_s: summary.stopped_s,
        avg_speed_mps: summary.avg_speed_mps,
        max_speed_mps: summary.max_speed_mps,
        best_100m_speed_mps: summary.best_100m_speed_mps,
        best_500m_speed_mps: summary.best_500m_speed_mps,
        max_speed_confidence: summary.max_speed_confidence,
        max_speed_point_position: summary.max_speed_point_position,
        elevation_gain_m: summary.elevation_gain_m,
        elevation_loss_m: summary.elevation_loss_m,
        min_elevation_m: summary.min_elevation_m,
        max_elevation_m: summary.max_elevation_m,
        quality_score: summary.quality_score,
        bounds: summary.bounds,
        stats: summary.stats,
        quality: summary.quality,
        error: nil
      }

      case track |> Track.changeset(attrs) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, updated} ->
        broadcast(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  def reanalyze(%Track{} = track) do
    with {:ok, updated} <-
           update_status(track, %{
             status: "queued",
             stage: "Queued for fresh analysis",
             progress: 0,
             error: nil
           }),
         {:ok, _job} <-
           %{track_id: updated.id, force: true}
           |> TrackAnalyzer.Workers.AnalyzeTrackWorker.new(replace: [:args, :scheduled_at])
           |> Oban.insert() do
      {:ok, updated}
    end
  end

  def delete_track(%Track{} = track) do
    case Repo.delete(track) do
      {:ok, deleted} ->
        broadcast(deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  defp clear_analysis(track_id) do
    for schema <- [Point, Segment, AnalysisEvent, Split, Rendering, RouteCell] do
      Repo.delete_all(from row in schema, where: row.track_id == ^track_id)
    end
  end

  defp insert_segments(track_id, segments) do
    Enum.reduce(segments, %{}, fn attrs, ids ->
      attrs = Map.put(attrs, :track_id, track_id)

      case %Segment{} |> Segment.changeset(attrs) |> Repo.insert() do
        {:ok, segment} -> Map.put(ids, {segment.track_position, segment.position}, segment.id)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp insert_points(track_id, segment_ids, points) do
    now = DateTime.utc_now()

    points
    |> Enum.map(fn point ->
      %{
        track_id: track_id,
        track_segment_id: Map.fetch!(segment_ids, {point.track_position, point.segment_position}),
        position: point.position,
        latitude: point.latitude,
        longitude: point.longitude,
        elevation_m: point.elevation_m,
        recorded_at: point.recorded_at,
        hdop: point.hdop,
        recorded_speed_mps: point.recorded_speed_mps,
        derived_speed_mps: point.derived_speed_mps,
        cumulative_distance_m: point.cumulative_distance_m,
        grade_percent: point.grade_percent,
        valid: point.valid,
        extras: point.extras,
        inserted_at: now
      }
    end)
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(Point, &1))
  end

  defp insert_rows(_schema, _track_id, []), do: :ok

  defp insert_rows(schema, track_id, rows) do
    now = DateTime.utc_now()

    records =
      Enum.map(rows, fn attrs ->
        attrs
        |> Map.put(:track_id, track_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(schema, records)
    :ok
  end

  defp apply_status_filter(query, status)
       when status in ~w(complete processing failed insufficient_data) do
    statuses = if status == "processing", do: @processing_statuses, else: [status]

    where(query, [track], track.status in ^statuses)
  end

  defp apply_status_filter(query, _status), do: query

  defp apply_search(query, search) when is_binary(search) and search != "" do
    term = "%#{String.replace(search, ~r/[%_]/, "")}%"
    where(query, [track], ilike(track.name, ^term) or ilike(track.source_filename, ^term))
  end

  defp apply_search(query, _search), do: query

  defp speed_metric("instantaneous"), do: :max_speed_mps
  defp speed_metric("500m"), do: :best_500m_speed_mps
  defp speed_metric(_metric), do: :best_100m_speed_mps

  defp speed_metric_name(:max_speed_mps), do: "instantaneous"
  defp speed_metric_name(:best_500m_speed_mps), do: "500m"
  defp speed_metric_name(:best_100m_speed_mps), do: "100m"

  defp speed_range(range) when range in ~w(90d 12m all), do: range
  defp speed_range(_range), do: "all"

  defp filter_speed_range(tracks, "all"), do: tracks

  defp filter_speed_range(tracks, range) do
    days = if range == "90d", do: 90, else: 365
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    Enum.filter(tracks, &(DateTime.compare(&1.started_at, cutoff) != :lt))
  end

  defp build_speed_history(tracks, metric) do
    tracks
    |> Enum.map(fn track ->
      %{
        track_id: track.id,
        name: track.name,
        started_at: track.started_at,
        instantaneous_mps: track.max_speed_mps,
        best_100m_mps: track.best_100m_speed_mps,
        best_500m_mps: track.best_500m_speed_mps,
        confidence: track.max_speed_confidence,
        metric_mps: Map.get(track, metric)
      }
    end)
    |> add_rolling_median()
    |> add_record_progression()
  end

  defp add_rolling_median(points) do
    points
    |> Enum.with_index()
    |> Enum.map(fn {point, index} ->
      window_start = max(index - 14, 0)

      median =
        points
        |> Enum.slice(window_start, index - window_start + 1)
        |> Enum.map(& &1.metric_mps)
        |> Enum.reject(&is_nil/1)
        |> median()

      Map.put(point, :rolling_median_mps, median)
    end)
  end

  defp add_record_progression(points) do
    {history, _record} =
      Enum.map_reduce(points, nil, fn point, record ->
        record = max_number(record, point.metric_mps)
        {Map.put(point, :record_mps, record), record}
      end)

    history
  end

  defp speed_record(tracks, field) do
    tracks
    |> Enum.reject(&is_nil(Map.get(&1, field)))
    |> Enum.max_by(&Map.get(&1, field), fn -> nil end)
    |> case do
      nil ->
        nil

      track ->
        %{
          track_id: track.id,
          name: track.name,
          started_at: track.started_at,
          speed_mps: Map.get(track, field)
        }
    end
  end

  defp speed_leaders(tracks, metric) do
    tracks
    |> Enum.reject(&is_nil(Map.get(&1, metric)))
    |> Enum.sort_by(&Map.get(&1, metric), :desc)
    |> Enum.take(10)
  end

  defp recent_speed_delta(history) do
    values = history |> Enum.map(& &1.metric_mps) |> Enum.reject(&is_nil/1)
    recent = values |> Enum.take(-15) |> median()
    previous = values |> Enum.drop(-15) |> Enum.take(-15) |> median()

    if is_number(recent) and is_number(previous) and previous > 0,
      do: (recent - previous) / previous * 100,
      else: nil
  end

  defp max_number(nil, right), do: right
  defp max_number(left, nil), do: left
  defp max_number(left, right), do: max(left, right)

  defp build_share_summary(tracks) do
    distance_m = sum(tracks, :distance_m)
    moving_s = sum(tracks, :moving_s)
    peak_track = max_record(tracks, :max_speed_mps)

    %{
      track_count: length(tracks),
      distance_m: distance_m,
      moving_s: moving_s,
      elevation_gain_m: sum(tracks, :elevation_gain_m),
      avg_speed_mps: if(moving_s > 0, do: distance_m / moving_s, else: nil),
      max_speed_mps: peak_track && peak_track.max_speed_mps,
      max_speed_confidence: peak_track && peak_track.max_speed_confidence,
      best_100m_speed_mps: max_value(tracks, :best_100m_speed_mps),
      best_500m_speed_mps: max_value(tracks, :best_500m_speed_mps),
      longest_distance_m: max_value(tracks, :distance_m),
      highest_elevation_gain_m: max_value(tracks, :elevation_gain_m),
      longest_moving_s: max_value(tracks, :moving_s),
      quality_score: average(tracks, :quality_score),
      activity:
        tracks
        |> Enum.reject(&is_nil(&1.started_at))
        |> Enum.sort_by(& &1.started_at, DateTime)
        |> Enum.map(&%{started_at: &1.started_at, distance_m: &1.distance_m || 0.0})
    }
  end

  defp max_record(records, field) do
    records
    |> Enum.reject(&is_nil(Map.get(&1, field)))
    |> Enum.max_by(&Map.get(&1, field), fn -> nil end)
  end

  defp max_value(records, field) do
    case max_record(records, field) do
      nil -> nil
      record -> Map.get(record, field)
    end
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp monthly_totals(tracks) do
    tracks
    |> Enum.reject(&is_nil(&1.started_at))
    |> Enum.group_by(&Calendar.strftime(&1.started_at, "%Y-%m"))
    |> Enum.map(fn {month, month_tracks} ->
      %{
        month: month,
        distance_m: sum(month_tracks, :distance_m),
        moving_s: sum(month_tracks, :moving_s),
        elevation_gain_m: sum(month_tracks, :elevation_gain_m),
        track_count: length(month_tracks)
      }
    end)
    |> Enum.sort_by(& &1.month)
  end

  defp sum(records, field) do
    records
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp average([], _field), do: nil

  defp average(records, field) do
    values = records |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values) / length(values)
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values, DateTime)
  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values, DateTime)

  defp broadcast_result({:ok, track} = result) do
    broadcast(track)
    result
  end

  defp broadcast_result(result), do: result

  defp broadcast(track) do
    Phoenix.PubSub.broadcast(TrackAnalyzer.PubSub, @topic, {:track_updated, track})
    Phoenix.PubSub.broadcast(TrackAnalyzer.PubSub, topic(track.id), {:track_updated, track})
  end

  defp topic(track_id), do: "track:#{track_id}"
end
