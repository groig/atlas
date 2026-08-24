defmodule TrackAnalyzer.Tracks.GPX do
  @moduledoc """
  Streaming GPX reader for OsmAnd-recorded tracks.
  """

  alias TrackAnalyzer.Tracks.GPXHandler

  @chunk_size 64 * 1024

  def parse_file(path) do
    if contains_doctype?(path) do
      {:error, :doctype_not_allowed}
    else
      path
      |> File.stream!([], @chunk_size)
      |> Saxy.parse_stream(GPXHandler, GPXHandler.initial_state())
      |> normalize_result(path)
    end
  rescue
    error in File.Error -> {:error, {:file_error, error.reason}}
  end

  defp normalize_result({:ok, state}, path) do
    points =
      state.points
      |> Enum.reverse()
      |> Enum.reduce([], fn point, acc ->
        with {latitude, ""} <- Float.parse(point.latitude || ""),
             {longitude, ""} <- Float.parse(point.longitude || ""),
             true <- latitude >= -90 and latitude <= 90,
             true <- longitude >= -180 and longitude <= 180 do
          [%{point | latitude: latitude, longitude: longitude} | acc]
        else
          _invalid -> acc
        end
      end)
      |> Enum.reverse()

    default_name = path |> Path.basename(".gpx") |> String.replace("_", " ")

    {:ok,
     %{
       name: state.name || default_name,
       creator: state.creator,
       segments: Enum.reverse(state.segments),
       points: points,
       warnings: Enum.reverse(state.warnings),
       invalid_point_count: length(state.points) - length(points)
     }}
  end

  defp normalize_result({:error, %{__exception__: true} = error}, _path),
    do: {:error, {:invalid_gpx, Exception.message(error)}}

  defp normalize_result({:error, _reason} = error, _path), do: error
  defp normalize_result(other, _path), do: {:error, {:invalid_gpx, inspect(other)}}

  defp contains_doctype?(path) do
    path
    |> File.stream!([], @chunk_size)
    |> Enum.any?(&String.contains?(&1, "<!DOCTYPE"))
  end
end
