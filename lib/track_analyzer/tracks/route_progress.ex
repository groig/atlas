defmodule TrackAnalyzer.Tracks.RouteProgress do
  @moduledoc """
  Builds matched-route groups and derives conservative progress signals.

  All labels describe changes in recorded performance. They intentionally do
  not claim changes in fitness, which would require physiological sensor data.
  """

  import Ecto.Query

  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Settings.AppSetting

  alias TrackAnalyzer.Tracks.{
    Rendering,
    RouteCluster,
    RouteClusterMembership,
    RouteMatcher,
    Track
  }

  @topic "route_progress"
  @setting_key "route_progress"
  @stale_after_hours 24

  def subscribe, do: Phoenix.PubSub.subscribe(TrackAnalyzer.PubSub, @topic)

  def enqueue_rebuild(opts \\ []) do
    delay = Keyword.get(opts, :delay, 0)
    worker = inspect(TrackAnalyzer.Workers.RebuildRouteClustersWorker)

    pending =
      Oban.Job
      |> where(
        [job],
        job.worker == ^worker and
          job.state in ["scheduled", "available", "retryable", "suspended"]
      )
      |> order_by([job], desc: job.id)
      |> limit(1)
      |> Repo.one()

    case pending do
      %Oban.Job{state: state} = job when state in ["scheduled", "available"] ->
        job
        |> Ecto.Changeset.change(%{
          args: %{"reason" => Keyword.get(opts, :reason, "requested")},
          scheduled_at: DateTime.add(DateTime.utc_now(), delay, :second),
          state: if(delay > 0, do: "scheduled", else: "available")
        })
        |> Repo.update()

      %Oban.Job{} = job ->
        {:ok, job}

      nil ->
        %{reason: Keyword.get(opts, :reason, "requested")}
        |> TrackAnalyzer.Workers.RebuildRouteClustersWorker.new(schedule_in: delay)
        |> Oban.insert()
    end
  end

  def ensure_fresh do
    status = status()

    if status.state in [:missing, :stale] do
      enqueue_rebuild(reason: Atom.to_string(status.state))
    else
      {:ok, :fresh}
    end
  end

  def status do
    eligible_count = eligible_query() |> Repo.aggregate(:count, :id)
    setting = Repo.get_by(AppSetting, key: @setting_key)

    cond do
      is_nil(setting) ->
        %{state: :missing, eligible_count: eligible_count, rebuilt_at: nil}

      stale_setting?(setting, eligible_count) ->
        %{state: :stale, eligible_count: eligible_count, rebuilt_at: setting.updated_at}

      true ->
        %{state: :ready, eligible_count: eligible_count, rebuilt_at: setting.updated_at}
    end
  end

  def rebuild do
    tracks =
      eligible_query()
      |> order_by([track], asc: track.id)
      |> preload([:renderings])
      |> Repo.all()

    features =
      tracks
      |> Task.async_stream(&RouteMatcher.feature/1,
        ordered: true,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, feature}} -> [feature]
        _unusable -> []
      end)

    pairs = build_pair_index(features)
    groups = features |> build_groups(pairs) |> Enum.filter(&(length(&1) >= 2))
    result = reconcile(groups, pairs, length(features))
    broadcast({:route_progress_rebuilt, result})
    {:ok, result}
  end

  def summary(filters \\ %{}) do
    all_clusters =
      RouteCluster
      |> order_by([cluster], desc: cluster.track_count, asc: cluster.name)
      |> preload([:representative_track, memberships: :track])
      |> Repo.all()
      |> Enum.map(&hydrate_cluster/1)

    clusters = filter_clusters(all_clusters, filters)

    complete_tracks =
      Track
      |> where([track], track.status == "complete" and not is_nil(track.started_at))
      |> order_by([track], asc: track.started_at)
      |> Repo.all()

    %{
      clusters: clusters,
      activities:
        all_clusters |> Enum.map(& &1.activity_type) |> compact() |> Enum.uniq() |> Enum.sort(),
      cluster_count: length(clusters),
      matched_track_count: Enum.sum(Enum.map(clusters, & &1.track_count)),
      improving_count: Enum.count(clusters, &(&1.trend.direction == "faster")),
      steady_count: Enum.count(clusters, &(&1.trend.direction == "steady")),
      volume: weekly_volume(complete_tracks),
      effort_trends: effort_trends(complete_tracks),
      streak_weeks: weekly_streak(complete_tracks),
      status: status()
    }
  end

  def get_cluster!(id) do
    RouteCluster
    |> Repo.get!(id)
    |> Repo.preload([:representative_track, memberships: [track: :renderings]])
    |> hydrate_cluster()
    |> Map.put(:sectors, sector_comparison(id))
  end

  def matched_cluster_for_track(track_id) do
    RouteClusterMembership
    |> where([membership], membership.track_id == ^track_id)
    |> preload([:track, route_cluster: [:representative_track, memberships: :track]])
    |> Repo.one()
    |> case do
      nil -> nil
      membership -> %{membership | route_cluster: hydrate_cluster(membership.route_cluster)}
    end
  end

  def sector_comparison(cluster_id) do
    attempts =
      RouteClusterMembership
      |> where([membership], membership.route_cluster_id == ^cluster_id)
      |> join(:inner, [membership], track in assoc(membership, :track))
      |> where([_membership, track], not is_nil(track.started_at))
      |> order_by([_membership, track], desc: track.started_at)
      |> preload([_membership, track], track: [:renderings])
      |> Repo.all()
      |> Enum.map(& &1.track)

    case attempts do
      [latest | prior] ->
        prior = Enum.take(prior, 5)
        latest_speeds = sector_speeds(latest)
        prior_speeds = Enum.map(prior, &sector_speeds/1)

        latest_speeds
        |> Enum.with_index()
        |> Enum.map(fn {speed, index} ->
          baseline = prior_speeds |> Enum.map(&Enum.at(&1, index)) |> compact() |> median()
          delta = percent_delta(speed, baseline)

          %{
            number: index + 1,
            latest_speed_mps: speed,
            baseline_speed_mps: baseline,
            delta_percent: delta,
            direction: classify_delta(delta, 2.0)
          }
        end)

      _insufficient ->
        []
    end
  end

  def trend(attempts) do
    attempts =
      attempts
      |> Enum.filter(&(is_number(&1.avg_speed_mps) and not is_nil(&1.started_at)))
      |> Enum.sort_by(& &1.started_at, DateTime)

    speeds = Enum.map(attempts, & &1.avg_speed_mps)
    count = length(speeds)
    threshold = noise_floor(speeds)

    {recent, baseline, signal} =
      cond do
        count >= 6 ->
          {median(Enum.take(speeds, -3)), median(speeds |> Enum.drop(-3) |> Enum.take(-3)),
           "recent 3 vs prior 3"}

        count >= 2 ->
          {List.last(speeds), median(Enum.drop(speeds, -1)), "latest vs earlier attempts"}

        true ->
          {nil, nil, "more attempts needed"}
      end

    delta = percent_delta(recent, baseline)

    %{
      direction: classify_delta(delta, threshold * 100),
      delta_percent: delta,
      recent_speed_mps: recent,
      baseline_speed_mps: baseline,
      noise_floor_percent: threshold * 100,
      signal: signal,
      attempt_count: count
    }
  end

  defp eligible_query do
    from track in Track,
      as: :track,
      where:
        track.status == "complete" and not is_nil(track.started_at) and
          track.distance_m >= 500.0 and
          track.moving_s > 0.0 and track.quality_score >= 70.0,
      where:
        exists(
          from rendering in Rendering,
            where: rendering.track_id == parent_as(:track).id and rendering.level == "overview",
            select: 1
        ),
      select: track
  end

  defp build_pair_index(features) do
    pairs =
      for {left, left_index} <- Enum.with_index(features),
          right <- Enum.drop(features, left_index + 1),
          do: {left, right}

    pairs
    |> Task.async_stream(
      fn {left, right} ->
        {pair_key(left.track.id, right.track.id), RouteMatcher.match(left, right)}
      end,
      ordered: false,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, {:ok, match}}}, index -> Map.put(index, key, match)
      _not_a_match, index -> index
    end)
  end

  defp build_groups(features, pairs) do
    Enum.reduce(features, [], fn feature, groups ->
      candidates =
        groups
        |> Enum.with_index()
        |> Enum.filter(fn {group, _index} ->
          Enum.all?(group, &Map.has_key?(pairs, pair_key(feature.track.id, &1.track.id)))
        end)
        |> Enum.map(fn {group, index} ->
          mean_similarity =
            group
            |> Enum.map(&Map.fetch!(pairs, pair_key(feature.track.id, &1.track.id)).similarity)
            |> average()

          {mean_similarity, -index, index}
        end)

      case Enum.max(candidates, fn -> nil end) do
        nil -> groups ++ [[feature]]
        {_similarity, _stable_order, index} -> List.update_at(groups, index, &(&1 ++ [feature]))
      end
    end)
  end

  defp reconcile(groups, pairs, eligible_count) do
    existing =
      RouteCluster
      |> preload([:memberships])
      |> Repo.all()

    {assignments, used_ids} = reconcile_assignments(groups, existing)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Repo.delete_all(RouteClusterMembership)

      existing
      |> Enum.reject(&MapSet.member?(used_ids, &1.id))
      |> Enum.each(&Repo.delete!/1)

      Enum.each(used_ids, fn id ->
        Repo.update_all(
          from(cluster in RouteCluster, where: cluster.id == ^id),
          set: [fingerprint: "rebuilding-#{id}-#{System.unique_integer([:positive])}"]
        )
      end)

      clusters =
        assignments
        |> Enum.with_index(1)
        |> Enum.map(fn {{group, previous}, position} ->
          representative = medoid(group, pairs)
          attempts = group |> Enum.map(& &1.track) |> Enum.sort_by(& &1.started_at, DateTime)
          pair_similarities = group_pair_similarities(group, pairs)
          route_trend = trend(attempts)
          confidence = confidence(length(group), average(pair_similarities), attempts)
          track_ids = Enum.map(group, & &1.track.id)

          attrs = %{
            name:
              if(previous, do: previous.name, else: route_name(representative.track, position)),
            fingerprint: cluster_fingerprint(track_ids),
            track_count: length(group),
            representative_track_id: representative.track.id,
            activity_type: common_activity(group),
            matcher_version: RouteMatcher.matcher_version(),
            stats: %{
              "average_similarity" => average(pair_similarities),
              "confidence" => confidence,
              "trend" => stringify_keys(route_trend),
              "first_attempt_at" => attempts |> List.first() |> iso_date(),
              "latest_attempt_at" => attempts |> List.last() |> iso_date()
            }
          }

          cluster =
            case previous do
              nil -> %RouteCluster{}
              cluster -> cluster
            end
            |> RouteCluster.changeset(attrs)
            |> Repo.insert_or_update!()

          Enum.each(group, fn feature ->
            match = member_match(feature, representative, pairs)

            %RouteClusterMembership{}
            |> RouteClusterMembership.changeset(%{
              route_cluster_id: cluster.id,
              track_id: feature.track.id,
              similarity: match.similarity,
              metrics: match.metrics
            })
            |> Repo.insert!()
          end)

          cluster
        end)

      setting_value = %{
        "eligible_count" => eligible_count,
        "cluster_count" => length(clusters),
        "matcher_version" => RouteMatcher.matcher_version(),
        "rebuilt_at" => DateTime.to_iso8601(now)
      }

      case Repo.get_by(AppSetting, key: @setting_key) do
        nil -> %AppSetting{key: @setting_key}
        setting -> setting
      end
      |> AppSetting.changeset(%{value: setting_value})
      |> Repo.insert_or_update!()

      %{
        cluster_count: length(clusters),
        matched_track_count: Enum.sum(Enum.map(groups, &length/1)),
        eligible_track_count: eligible_count
      }
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> raise "route progress rebuild failed: #{inspect(reason)}"
    end
  end

  defp reconcile_assignments(groups, existing) do
    Enum.map_reduce(groups, MapSet.new(), fn group, used ->
      group_ids = MapSet.new(Enum.map(group, & &1.track.id))

      previous =
        existing
        |> Enum.reject(&MapSet.member?(used, &1.id))
        |> Enum.map(fn cluster ->
          membership_ids = MapSet.new(Enum.map(cluster.memberships, & &1.track_id))
          overlap = MapSet.intersection(group_ids, membership_ids) |> MapSet.size()
          {overlap, -cluster.id, cluster}
        end)
        |> Enum.filter(fn {overlap, _id, _cluster} -> overlap > 0 end)
        |> Enum.max(fn -> nil end)
        |> case do
          nil -> nil
          {_overlap, _id, cluster} -> cluster
        end

      used = if previous, do: MapSet.put(used, previous.id), else: used
      {{group, previous}, used}
    end)
  end

  defp medoid(group, pairs) do
    Enum.max_by(group, fn candidate ->
      total =
        group
        |> Enum.reject(&(&1.track.id == candidate.track.id))
        |> Enum.map(&Map.fetch!(pairs, pair_key(candidate.track.id, &1.track.id)).similarity)
        |> Enum.sum()

      {total, -candidate.track.id}
    end)
  end

  defp member_match(feature, representative, _pairs)
       when feature.track.id == representative.track.id,
       do: %{similarity: 1.0, metrics: %{"representative" => true}}

  defp member_match(feature, representative, pairs),
    do: Map.fetch!(pairs, pair_key(feature.track.id, representative.track.id))

  defp group_pair_similarities(group, pairs) do
    for {left, index} <- Enum.with_index(group),
        right <- Enum.drop(group, index + 1),
        do: Map.fetch!(pairs, pair_key(left.track.id, right.track.id)).similarity
  end

  defp hydrate_cluster(%RouteCluster{} = cluster) do
    attempts =
      cluster.memberships
      |> Enum.map(& &1.track)
      |> Enum.sort_by(& &1.started_at, DateTime)

    %{
      id: cluster.id,
      name: cluster.name,
      activity_type: cluster.activity_type,
      track_count: cluster.track_count,
      representative_track: cluster.representative_track,
      attempts: attempts,
      memberships: cluster.memberships,
      average_similarity: get_in(cluster.stats, ["average_similarity"]) || 0.0,
      confidence: get_in(cluster.stats, ["confidence"]) || "low",
      trend: trend(attempts),
      first_attempt_at: attempts |> List.first() |> track_date(),
      latest_attempt_at: attempts |> List.last() |> track_date()
    }
  end

  defp filter_clusters(clusters, filters) do
    activity = Map.get(filters, "activity", "all")
    trend_filter = Map.get(filters, "trend", "all")
    minimum_attempts = parse_integer(Map.get(filters, "attempts", "2"), 2)

    Enum.filter(clusters, fn cluster ->
      (activity == "all" or cluster.activity_type == activity) and
        (trend_filter == "all" or cluster.trend.direction == trend_filter) and
        cluster.track_count >= minimum_attempts
    end)
  end

  defp sector_speeds(track) do
    rendering =
      Enum.find(track.renderings, &(&1.level == "detail")) ||
        Enum.find(track.renderings, &(&1.level == "overview"))

    series = if rendering, do: rendering.series, else: %{}
    distances = Map.get(series, "distance_km", [])
    speeds = Map.get(series, "speed_kmh", [])
    times = Map.get(series, "time", [])
    total_distance = distances |> compact() |> List.last()

    for sector <- 0..9 do
      sector_speed(distances, speeds, times, total_distance, sector)
    end
  end

  defp sector_speed(_distances, _speeds, _times, nil, _sector), do: nil

  defp sector_speed(distances, speeds, times, total_distance, sector) do
    start_distance = total_distance * sector / 10
    end_distance = total_distance * (sector + 1) / 10
    start_index = first_index_at_or_after(distances, start_distance)
    end_index = first_index_at_or_after(distances, end_distance)

    with start_index when is_integer(start_index) <- start_index,
         end_index when is_integer(end_index) <- end_index,
         {:ok, started_at} <- parse_time(Enum.at(times, start_index)),
         {:ok, ended_at} <- parse_time(Enum.at(times, end_index)),
         duration when duration > 0 <- DateTime.diff(ended_at, started_at, :millisecond) / 1_000 do
      (end_distance - start_distance) * 1_000 / duration
    else
      _missing_time ->
        distances
        |> Enum.zip(speeds)
        |> Enum.filter(fn {distance, speed} ->
          is_number(distance) and is_number(speed) and distance >= start_distance and
            distance <= end_distance
        end)
        |> Enum.map(&elem(&1, 1))
        |> average()
        |> case do
          nil -> nil
          speed_kmh -> speed_kmh / 3.6
        end
    end
  end

  defp first_index_at_or_after(distances, target) do
    Enum.find_index(distances, &(is_number(&1) and &1 >= target))
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_time(_value), do: :error

  defp weekly_volume(tracks) do
    today = Date.utc_today()
    current_week = Date.beginning_of_week(today)

    weeks =
      for offset <- 11..0//-1 do
        week = Date.add(current_week, -7 * offset)
        week_end = Date.add(week, 7)

        week_tracks =
          Enum.filter(tracks, fn track ->
            date = DateTime.to_date(track.started_at)
            Date.compare(date, week) != :lt and Date.compare(date, week_end) == :lt
          end)

        %{
          week: Date.to_iso8601(week),
          distance_m: Enum.sum(Enum.map(week_tracks, &(&1.distance_m || 0.0))),
          moving_s: Enum.sum(Enum.map(week_tracks, &(&1.moving_s || 0.0))),
          track_count: length(week_tracks)
        }
      end

    recent = weeks |> Enum.take(-4) |> Enum.map(& &1.distance_m) |> Enum.sum()
    prior = weeks |> Enum.drop(-4) |> Enum.take(-4) |> Enum.map(& &1.distance_m) |> Enum.sum()
    %{weeks: weeks, delta_percent: percent_delta(recent, prior)}
  end

  defp effort_trends(tracks) do
    for {label, field} <- [{"100 m", :best_100m_speed_mps}, {"500 m", :best_500m_speed_mps}] do
      values = tracks |> Enum.map(&Map.get(&1, field)) |> compact()
      recent = values |> Enum.take(-5) |> median()
      prior = values |> Enum.drop(-5) |> Enum.take(-5) |> median()

      %{
        label: label,
        recent_speed_mps: recent,
        delta_percent: percent_delta(recent, prior),
        record_speed_mps: Enum.max(values, fn -> nil end)
      }
    end
  end

  defp weekly_streak([]), do: 0

  defp weekly_streak(tracks) do
    occupied =
      tracks
      |> Enum.map(&(&1.started_at |> DateTime.to_date() |> Date.beginning_of_week()))
      |> MapSet.new()

    latest = occupied |> Enum.max(Date, fn -> Date.beginning_of_week(Date.utc_today()) end)

    Stream.iterate(latest, &Date.add(&1, -7))
    |> Enum.reduce_while(0, fn week, count ->
      if MapSet.member?(occupied, week), do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  defp confidence(count, similarity, attempts) do
    minimum_quality =
      attempts |> Enum.map(& &1.quality_score) |> compact() |> Enum.min(fn -> 0 end)

    cond do
      count >= 10 and similarity >= 0.85 and minimum_quality >= 85 -> "high"
      count >= 6 and similarity >= 0.78 and minimum_quality >= 75 -> "medium"
      true -> "low"
    end
  end

  defp noise_floor(speeds) do
    center = median(speeds)

    if is_number(center) and center > 0 do
      mad = speeds |> Enum.map(&abs(&1 - center)) |> median()
      max(0.02, 1.4826 * mad / center)
    else
      0.02
    end
  end

  defp classify_delta(nil, _threshold), do: "building"
  defp classify_delta(delta, threshold) when delta > threshold, do: "faster"
  defp classify_delta(delta, threshold) when delta < -threshold, do: "slower"
  defp classify_delta(_delta, _threshold), do: "steady"

  defp stale_setting?(setting, eligible_count) do
    recorded_count = get_in(setting.value, ["eligible_count"])
    matcher_version = get_in(setting.value, ["matcher_version"])
    age = DateTime.diff(DateTime.utc_now(), setting.updated_at, :hour)

    recorded_count != eligible_count or matcher_version != RouteMatcher.matcher_version() or
      age >= @stale_after_hours
  end

  defp common_activity(group) do
    activities = group |> Enum.map(& &1.activity_type) |> compact() |> Enum.uniq()
    if length(activities) == 1, do: List.first(activities)
  end

  defp route_name(track, position) do
    name = present(track.name) || "Matched route #{position}"
    String.slice(name, 0, 80)
  end

  defp cluster_fingerprint(track_ids) do
    "v#{RouteMatcher.matcher_version()}:#{Enum.sort(track_ids) |> Enum.join(",")}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp pair_key(left_id, right_id) when left_id < right_id, do: {left_id, right_id}
  defp pair_key(left_id, right_id), do: {right_id, left_id}

  defp percent_delta(value, baseline)
       when is_number(value) and is_number(baseline) and baseline > 0,
       do: (value - baseline) / baseline * 100

  defp percent_delta(_value, _baseline), do: nil

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)
  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp compact(values), do: Enum.reject(values, &is_nil/1)
  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
  defp track_date(nil), do: nil
  defp track_date(track), do: track.started_at
  defp iso_date(nil), do: nil
  defp iso_date(track), do: DateTime.to_iso8601(track.started_at)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _invalid -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(TrackAnalyzer.PubSub, @topic, message)
end
