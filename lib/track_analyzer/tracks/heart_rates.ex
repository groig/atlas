defmodule TrackAnalyzer.Tracks.HeartRates do
  @moduledoc "HR history and optional, explicitly configured intensity bands."
  import Ecto.Query
  import Ecto.Changeset

  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Settings.AppSetting
  alias TrackAnalyzer.Tracks.{HeartRate, Point, Track}

  @key "heart_rate_profile"
  @topic "heart_rate"
  @types %{
    mode: :string,
    maximum: :integer,
    z1: :integer,
    z2: :integer,
    z3: :integer,
    z4: :integer,
    z5: :integer
  }

  def subscribe, do: Phoenix.PubSub.subscribe(TrackAnalyzer.PubSub, @topic)
  def broadcast, do: Phoenix.PubSub.broadcast(TrackAnalyzer.PubSub, @topic, :heart_rate_updated)

  def profile do
    case Repo.get_by(AppSetting, key: @key) do
      nil -> %{"mode" => "none", "revision" => 0}
      setting -> setting.value
    end
  end

  def profile_changeset(params \\ %{}) do
    {%{mode: "none", z1: 30}, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:mode])
    |> validate_inclusion(:mode, ~w(none maximum custom))
    |> validate_profile()
  end

  defp validate_profile(changeset) do
    case get_field(changeset, :mode) do
      "maximum" ->
        changeset
        |> validate_required([:maximum])
        |> validate_number(:maximum, greater_than_or_equal_to: 100, less_than_or_equal_to: 240)

      "custom" ->
        fields = [:z1, :z2, :z3, :z4, :z5]
        changeset = validate_required(changeset, fields)

        changeset =
          Enum.reduce(
            fields,
            changeset,
            &validate_number(&2, &1, greater_than_or_equal_to: 30, less_than: 240)
          )

        edges = Enum.map(fields, &get_field(changeset, &1))

        cond do
          Enum.any?(edges, &is_nil/1) ->
            changeset

          hd(edges) != 30 ->
            add_error(changeset, :z1, "must be 30 to include all usable readings")

          edges != Enum.sort(Enum.uniq(edges)) ->
            add_error(changeset, :z2, "boundaries must increase strictly")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  def save_profile(params) do
    with {:ok, values} <- params |> profile_changeset() |> apply_action(:update) do
      result =
        Repo.transaction(fn ->
          # The same lock orders settings writes, recalibration and track analysis.
          lock_profile()
          existing = Repo.get_by(AppSetting, key: @key)
          revision = if(existing, do: existing.value["revision"] || 0, else: 0) + 1

          edges =
            case values.mode do
              "maximum" -> [30 | Enum.map([0.6, 0.7, 0.8, 0.9], &round(values.maximum * &1))]
              "custom" -> Enum.map([:z1, :z2, :z3, :z4, :z5], &Map.fetch!(values, &1))
              _ -> nil
            end

          value =
            values
            |> Map.new(fn {key, val} -> {Atom.to_string(key), val} end)
            |> Map.merge(%{"edges" => edges, "revision" => revision})

          (existing || %AppSetting{})
          |> AppSetting.changeset(%{key: @key, value: value})
          |> Repo.insert_or_update!()

          %{revision: revision}
          |> TrackAnalyzer.Workers.RecalibrateHeartRateWorker.new()
          |> Oban.insert!()

          value
        end)

      if match?({:ok, _}, result), do: broadcast()
      result
    end
  end

  def lock_profile, do: Repo.query!("SELECT pg_advisory_xact_lock(714382091)")

  def recalibrate do
    ids = recorded_query() |> select([t], t.id) |> Repo.all()

    Enum.each(ids, fn id ->
      Repo.transaction(fn ->
        lock_profile()
        track = Track |> where([t], t.id == ^id) |> lock("FOR UPDATE") |> Repo.one()

        if track do
          hr = HeartRate.with_zones(track.stats["heart_rate"], profile())
          track |> change(stats: Map.put(track.stats, "heart_rate", hr)) |> Repo.update!()
        end
      end)
    end)

    broadcast()
    :ok
  end

  def summary_for(track, profile \\ nil) do
    HeartRate.with_zones(track.stats["heart_rate"] || %{}, profile || profile())
  end

  def count, do: recorded_query() |> Repo.aggregate(:count, :id)

  def pending_count do
    revision = profile()["revision"] || 0

    recorded_query()
    |> where(
      [t],
      fragment(
        "COALESCE((?->'heart_rate'->>'zone_revision')::integer, 0) <> ?",
        t.stats,
        ^revision
      )
    )
    |> Repo.aggregate(:count, :id)
  end

  def overview(today \\ Date.utc_today()) do
    profile = profile()
    tracks = recorded_query() |> order_by([t], desc: t.started_at, desc: t.id) |> Repo.all()
    tracks = Enum.map(tracks, &%{track: &1, hr: summary_for(&1, profile), date: local_date(&1)})

    weeks =
      tracks
      |> Enum.reject(&is_nil(&1.date))
      |> Enum.group_by(&Date.beginning_of_week(&1.date))
      |> Enum.sort_by(&elem(&1, 0), Date)
      |> Enum.map(fn {week, rows} ->
        %{
          "week" => Date.to_iso8601(week),
          "tracks" => length(rows),
          "covered_s" => total(rows, "covered_s"),
          "load" => if(profile["edges"], do: total_load(rows)),
          "distribution" => combined_distribution(rows)
        }
      end)

    %{
      profile: profile,
      tracks: tracks,
      count: length(tracks),
      weeks: fill_weeks(weeks),
      load_history: load_history(tracks, today, profile),
      covered_s: total(tracks, "covered_s"),
      load_7: period_load(tracks, today, 7, profile),
      load_28: period_load(tracks, today, 28, profile)
    }
  end

  def selection(track, from, until) when is_number(from) and is_number(until) do
    duration = track.elapsed_s || 0

    if track.started_at && from >= 0 && until > from && until <= duration do
      first = DateTime.add(track.started_at, floor(from) - 30, :second)
      last = DateTime.add(track.started_at, ceil(until) + 30, :second)

      points =
        Point
        |> where(
          [p],
          p.track_id == ^track.id and p.recorded_at >= ^first and p.recorded_at <= ^last
        )
        |> order_by([p], asc: p.position)
        |> Repo.all()

      {:ok, HeartRate.selection(points, track.started_at, from, until)}
    else
      {:error, :invalid_range}
    end
  end

  def selection(_, _, _), do: {:error, :invalid_range}

  defp recorded_query do
    Track
    |> where(
      [t],
      t.status == "complete" and
        fragment("COALESCE((?->'heart_rate'->>'sample_count')::integer, 0) > 0", t.stats)
    )
  end

  defp total(rows, key), do: Enum.reduce(rows, 0.0, &((&1.hr[key] || 0) + &2))
  defp period_load(_rows, _today, _days, %{"mode" => "none"}), do: nil

  defp period_load(rows, today, days, _profile) do
    start = Date.add(today, -(days - 1))

    selected =
      Enum.filter(
        rows,
        &(&1.date && Date.compare(&1.date, start) != :lt && Date.compare(&1.date, today) != :gt)
      )

    total_load(selected)
  end

  defp total_load(rows) do
    recorded = Enum.filter(rows, &is_number(&1.hr["load"]))
    if recorded == [], do: nil, else: total(recorded, "load")
  end

  defp fill_weeks([]), do: []

  defp fill_weeks(weeks) do
    by_week = Map.new(weeks, &{&1["week"], &1})
    first = Date.from_iso8601!(hd(weeks)["week"])
    last = Date.from_iso8601!(List.last(weeks)["week"])
    first = Enum.max([first, Date.add(last, -7 * 103)], Date)

    Date.range(first, last, 7)
    |> Enum.map(fn day ->
      key = Date.to_iso8601(day)

      Map.get(by_week, key, %{
        "week" => key,
        "tracks" => 0,
        "covered_s" => nil,
        "load" => nil,
        "distribution" => []
      })
    end)
  end

  defp load_history(_rows, _today, %{"mode" => "none"}), do: []

  defp load_history(rows, today, profile) do
    dates = rows |> Enum.map(& &1.date) |> Enum.reject(&is_nil/1)

    if dates == [] do
      []
    else
      first = Enum.min(dates, Date)
      start = Enum.max([first, Date.add(today, -365)], Date)

      if Date.compare(start, today) == :gt,
        do: [],
        else:
          Date.range(start, today)
          |> Enum.map(fn date ->
            %{
              "date" => Date.to_iso8601(date),
              "load_7" => period_load(rows, date, 7, profile),
              "load_28" => period_load(rows, date, 28, profile)
            }
          end)
    end
  end

  defp combined_distribution(rows) do
    bins =
      rows
      |> Enum.flat_map(&(&1.hr["histogram"] || []))
      |> Enum.group_by(& &1["bpm"])
      |> Enum.map(fn {bpm, bins} ->
        %{"bpm" => bpm, "seconds" => Enum.reduce(bins, 0.0, &(&1["seconds"] + &2))}
      end)

    HeartRate.distribution(%{"histogram" => bins})
  end

  defp local_date(%{started_at: nil}), do: nil

  defp local_date(track) do
    case DateTime.shift_zone(track.started_at, track.timezone || "Etc/UTC") do
      {:ok, time} -> DateTime.to_date(time)
      _ -> DateTime.to_date(track.started_at)
    end
  end
end
