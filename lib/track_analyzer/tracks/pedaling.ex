defmodule TrackAnalyzer.Tracks.Pedaling do
  @moduledoc """
  Cadence and speed-sensor history across rides, built from the per-track
  summaries in `track.stats` so no track points are reread.
  """

  import Ecto.Query

  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Tracks.Track

  def count, do: sensor_query() |> Repo.aggregate(:count, :id)

  def overview do
    rows =
      sensor_query()
      |> order_by([t], desc: t.started_at, desc: t.id)
      |> Repo.all()
      |> Enum.map(fn track ->
        %{
          id: track.id,
          track: track,
          cadence: track.stats["cadence"] || %{},
          speed: track.stats["speed_sensor"] || %{}
        }
      end)

    cadence_rows = Enum.filter(rows, &((&1.cadence["sample_count"] || 0) > 0))
    speed_rows = Enum.filter(rows, &is_number(&1.speed["distance_difference_percent"]))
    pedaling_s = total(cadence_rows, "pedaling_s")
    moving_s = total(cadence_rows, "moving_s")
    coasting_s = total(cadence_rows, "coasting_s")

    %{
      tracks: rows,
      count: length(rows),
      cadence_count: length(cadence_rows),
      pedaling_s: pedaling_s,
      revolutions: total(cadence_rows, "revolutions"),
      average_rpm: weighted(cadence_rows, "average_rpm", "pedaling_s"),
      coasting_percent: if(moving_s > 0, do: coasting_s / moving_s * 100),
      history: history(cadence_rows),
      cadence: combined_cadence(cadence_rows),
      development: combined_development(cadence_rows),
      terrain: combined_terrain(cadence_rows),
      calibration: calibration(speed_rows),
      median_difference_percent:
        speed_rows |> Enum.map(& &1.speed["distance_difference_percent"]) |> median()
    }
  end

  defp sensor_query do
    Track
    |> where(
      [t],
      t.status == "complete" and
        (fragment("COALESCE((?->'cadence'->>'sample_count')::integer, 0) > 0", t.stats) or
           fragment("COALESCE((?->'speed_sensor'->>'sample_count')::integer, 0) > 0", t.stats))
    )
  end

  defp history(rows) do
    rows
    |> Enum.reject(&is_nil(&1.track.started_at))
    |> Enum.sort_by(& &1.track.started_at, DateTime)
    |> Enum.map(fn row ->
      %{
        "id" => row.id,
        "name" => row.track.name,
        "date" => DateTime.to_iso8601(row.track.started_at),
        "average_rpm" => row.cadence["average_rpm"],
        "coasting_percent" => row.cadence["coasting_percent"]
      }
    end)
  end

  defp combined_cadence(rows) do
    histogram =
      rows
      |> Enum.flat_map(&(&1.cadence["histogram"] || []))
      |> Enum.group_by(& &1["rpm"])
      |> Enum.sort()
      |> Enum.map(fn {rpm, bins} -> %{"rpm" => rpm, "seconds" => total_bins(bins)} end)

    %{"histogram" => histogram, "coasting_s" => total(rows, "coasting_s")}
  end

  defp combined_development(rows) do
    rows
    |> Enum.flat_map(&(&1.cadence["development"] || []))
    |> Enum.group_by(& &1["meters"])
    |> Enum.sort()
    |> Enum.map(fn {meters, bins} -> %{"meters" => meters, "seconds" => total_bins(bins)} end)
  end

  defp combined_terrain(rows) do
    rows
    |> Enum.flat_map(&(&1.cadence["terrain"] || []))
    |> Enum.group_by(&{&1["band"], &1["label"]})
    |> Enum.map(fn {{band, label}, bands} ->
      seconds = total_bins(bands)

      pedaling =
        Enum.map(bands, fn b -> {b, b["seconds"] * (1 - (b["coasting_percent"] || 0) / 100)} end)

      pedaling_s = Enum.reduce(pedaling, 0.0, &(elem(&1, 1) + &2))

      %{
        "band" => band,
        "label" => label,
        "seconds" => seconds,
        "average_rpm" =>
          if pedaling_s > 0 do
            pedaling
            |> Enum.filter(fn {b, _s} -> is_number(b["average_rpm"]) end)
            |> Enum.reduce(0.0, fn {b, s}, acc -> acc + b["average_rpm"] * s end)
            |> Kernel./(pedaling_s)
          end,
        "coasting_percent" => if(seconds > 0, do: (seconds - pedaling_s) / seconds * 100)
      }
    end)
    |> Enum.sort_by(
      &Enum.find_index(~w(descent flat rolling climb), fn key -> key == &1["band"] end)
    )
  end

  defp calibration(rows) do
    rows
    |> Enum.reject(&is_nil(&1.track.started_at))
    |> Enum.sort_by(& &1.track.started_at, DateTime)
    |> Enum.map(fn row ->
      %{
        "id" => row.id,
        "name" => row.track.name,
        "date" => DateTime.to_iso8601(row.track.started_at),
        "difference_percent" => row.speed["distance_difference_percent"]
      }
    end)
  end

  defp total(rows, key) do
    Enum.reduce(rows, 0.0, fn row, sum ->
      value = row.cadence[key]
      if is_number(value), do: sum + value, else: sum
    end)
  end

  defp total_bins(bins), do: Enum.reduce(bins, 0.0, &((&1["seconds"] || 0) + &2))

  defp weighted(rows, value_key, weight_key) do
    usable =
      Enum.filter(rows, &(is_number(&1.cadence[value_key]) and is_number(&1.cadence[weight_key])))

    weight = Enum.reduce(usable, 0.0, &(&1.cadence[weight_key] + &2))

    if weight > 0,
      do:
        Enum.reduce(usable, 0.0, &(&1.cadence[value_key] * &1.cadence[weight_key] + &2)) / weight
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end
end
