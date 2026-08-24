defmodule TrackAnalyzer.Storage.Local do
  @moduledoc """
  Durable content-addressed storage for private OsmAnd archives and extracted GPX files.
  """

  @buffer_size 128 * 1024

  def root do
    :track_analyzer
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:root)
  end

  def ensure_directories do
    Enum.each(~w(archives tracks staging), fn directory ->
      root()
      |> Path.join(directory)
      |> File.mkdir_p!()
    end)

    :ok
  end

  def store_archive(source_path, original_filename) do
    ensure_directories()

    with {:ok, sha256, byte_size} <- digest_file(source_path),
         target <- content_path("archives", sha256, ".osf"),
         :ok <- copy_once(source_path, target) do
      {:ok,
       %{
         sha256: sha256,
         byte_size: byte_size,
         storage_path: target,
         original_filename: safe_name(original_filename)
       }}
    end
  end

  def store_track(binary) when is_binary(binary) do
    ensure_directories()
    sha256 = Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
    target = content_path("tracks", sha256, ".gpx")

    case File.open(target, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        result = IO.binwrite(file, binary)
        File.close(file)

        case result do
          :ok -> {:ok, %{sha256: sha256, byte_size: byte_size(binary), storage_path: target}}
          {:error, reason} -> {:error, reason}
        end

      {:error, :eexist} ->
        {:ok, %{sha256: sha256, byte_size: byte_size(binary), storage_path: target}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete(path) when is_binary(path) do
    expanded = Path.expand(path)
    root = Path.expand(root())

    if String.starts_with?(expanded, root <> "/") do
      case File.rm(expanded) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      {:error, :outside_storage_root}
    end
  end

  def digest_file(path) do
    try do
      {hash, size} =
        path
        |> File.stream!([], @buffer_size)
        |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {context, size} ->
          {:crypto.hash_update(context, chunk), size + byte_size(chunk)}
        end)

      {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size}
    rescue
      error in File.Error -> {:error, error.reason}
    end
  end

  defp content_path(kind, sha256, extension) do
    directory =
      root()
      |> Path.join(kind)
      |> Path.join(String.slice(sha256, 0, 2))

    File.mkdir_p!(directory)
    Path.join(directory, sha256 <> extension)
  end

  defp copy_once(source, target) do
    if File.exists?(target) do
      :ok
    else
      temporary = target <> ".partial-#{System.unique_integer([:positive])}"

      with {:ok, _bytes} <- File.copy(source, temporary),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, :eexist} ->
          _ = File.rm(temporary)
          :ok

        {:error, reason} ->
          _ = File.rm(temporary)
          {:error, reason}
      end
    end
  end

  defp safe_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^[:alnum:]._-]+/u, "_")
    |> String.slice(0, 240)
  end
end
