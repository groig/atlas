defmodule TrackAnalyzer.Imports.SingleFile do
  @moduledoc """
  Treats a standalone GPX or FIT upload as a one-item archive, so it shares the
  OSF pipeline: content-addressed storage, deduplication and background analysis.
  """

  alias TrackAnalyzer.Tracks.FIT

  @formats ~w(osf gpx fit)
  @max_track_bytes 256 * 1024 * 1024
  @sniff_bytes 4096

  @doc "Upload format from a client filename, or nil when it is not supported."
  def format_for(filename) when is_binary(filename) do
    format = filename |> Path.extname() |> String.downcase() |> String.trim_leading(".")
    if format in @formats, do: format
  end

  def format_for(_filename), do: nil

  def inspect(path, format, original_filename) when format in ~w(gpx fit) do
    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- check_size(size),
         {:ok, head} <- read_head(path),
         :ok <- check_signature(format, head) do
      {:ok,
       %{
         version: nil,
         manifest: %{},
         items: [
           %{
             "type" => String.upcase(format),
             "subtype" => format,
             "file" => original_filename,
             "archive_path" => original_filename,
             "position" => 0
           }
         ],
         ignored_items: 0,
         warning: nil
       }}
    end
  end

  def read(path), do: File.read(path)

  defp check_size(size) when size > 0 and size <= @max_track_bytes, do: :ok
  defp check_size(0), do: {:error, :empty_file}
  defp check_size(_size), do: {:error, :track_file_too_large}

  defp read_head(path) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, @sniff_bytes) do
        data when is_binary(data) -> data
        _eof -> ""
      end
    end)
  end

  defp check_signature("fit", head) do
    if FIT.fit?(head), do: :ok, else: {:error, :not_a_fit_file}
  end

  defp check_signature("gpx", head) do
    if String.contains?(head, "<gpx"), do: :ok, else: {:error, :not_a_gpx_file}
  end
end
