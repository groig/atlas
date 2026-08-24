defmodule TrackAnalyzerWeb.FormatHelpers do
  @moduledoc false

  use Phoenix.Component

  def distance(nil), do: "—"
  def distance(meters) when meters >= 1_000, do: number(meters / 1_000, 1) <> " km"
  def distance(meters), do: number(meters, 0) <> " m"

  def elevation(nil), do: "—"
  def elevation(meters), do: number(meters, 0) <> " m"

  def speed(nil), do: "—"
  def speed(meters_per_second), do: number(meters_per_second * 3.6, 1) <> " km/h"

  def duration(nil), do: "—"

  def duration(seconds) do
    total = max(round(seconds), 0)
    hours = div(total, 3_600)
    minutes = total |> rem(3_600) |> div(60)

    cond do
      hours > 0 -> "#{hours}h #{String.pad_leading(Integer.to_string(minutes), 2, "0")}m"
      total >= 60 -> "#{minutes}m"
      true -> "#{total}s"
    end
  end

  def compact_number(nil), do: "—"
  def compact_number(number) when number >= 1_000_000, do: number(number / 1_000_000, 1) <> "m"
  def compact_number(number) when number >= 1_000, do: number(number / 1_000, 1) <> "k"
  def compact_number(number), do: number(number, 0)

  def percent(nil), do: "—"
  def percent(value), do: number(value, 0) <> "%"

  def local_date(datetime, timezone \\ nil)

  def local_date(nil, _timezone), do: "No timestamp"

  def local_date(%DateTime{} = datetime, timezone) do
    datetime
    |> maybe_shift(timezone)
    |> Calendar.strftime("%b %-d, %Y · %-I:%M %p")
  end

  def short_date(nil), do: "Undated"
  def short_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")

  def status_label("insufficient_data"), do: "Needs data"
  def status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()

  def status_classes(status) when status in ["complete"] do
    "bg-emerald-400/12 text-emerald-700 ring-emerald-500/20 dark:text-emerald-300"
  end

  def status_classes(status) when status in ["failed", "partial"] do
    "bg-red-400/12 text-red-700 ring-red-500/20 dark:text-red-300"
  end

  def status_classes(status) when status in ["insufficient_data"] do
    "bg-amber-400/12 text-amber-800 ring-amber-500/20 dark:text-amber-300"
  end

  def status_classes(_status) do
    "bg-cyan-400/12 text-cyan-800 ring-cyan-500/20 dark:text-cyan-300"
  end

  def json(value), do: Jason.encode!(value)

  defp number(value, precision) when is_integer(value), do: number(value * 1.0, precision)

  defp number(value, precision) do
    value
    |> Float.round(precision)
    |> :erlang.float_to_binary(decimals: precision)
  end

  defp maybe_shift(datetime, nil), do: datetime

  defp maybe_shift(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      _error -> datetime
    end
  end
end
