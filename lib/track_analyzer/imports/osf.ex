defmodule TrackAnalyzer.Imports.OSF do
  @moduledoc """
  Defensive reader for OsmAnd OSF exports.

  OSF is a ZIP container with a root items.json manifest. Only manifest-listed
  GPX entries are returned to the ingestion pipeline.
  """

  @max_manifest_bytes 20 * 1024 * 1024
  @max_gpx_items 2_000
  @max_entry_bytes 256 * 1024 * 1024
  @max_expanded_bytes 5 * 1024 * 1024 * 1024

  def inspect(path) do
    with_zip(path, fn handle ->
      with {:ok, entries} <- list_entries(handle),
           :ok <- validate_archive_entries(entries),
           {:ok, manifest_binary} <- read_entry(handle, "items.json"),
           :ok <- validate_manifest_size(manifest_binary),
           {:ok, manifest} <- Jason.decode(manifest_binary),
           {:ok, version, items} <- validate_manifest(manifest),
           {:ok, gpx_items} <- validate_gpx_items(items, entries) do
        warning =
          if version in 1..3,
            do: nil,
            else: "OsmAnd manifest version #{version} is newer than the tested versions 1–3"

        {:ok,
         %{
           version: version,
           manifest: manifest,
           items: gpx_items,
           ignored_items: length(items) - length(gpx_items),
           warning: warning
         }}
      end
    end)
  end

  def read_gpx(path, item_path) do
    with {:ok, normalized} <- normalize_path(item_path) do
      with_zip(path, &read_entry(&1, normalized))
    end
  end

  defp with_zip(path, fun) do
    case :zip.zip_open(String.to_charlist(path), [:memory]) do
      {:ok, handle} ->
        try do
          fun.(handle)
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        {:error, {:invalid_osf, reason}}
    end
  end

  defp list_entries(handle) do
    with {:ok, raw_entries} <- :zip.zip_list_dir(handle) do
      entries =
        Enum.reduce(raw_entries, %{}, fn
          {:zip_file, name, info, _comment, _offset, _compressed_size}, acc ->
            Map.update(acc, List.to_string(name), [entry_size(info)], &[entry_size(info) | &1])

          _entry, acc ->
            acc
        end)

      {:ok, entries}
    end
  end

  defp entry_size(info), do: elem(info, 1)

  defp validate_archive_entries(entries) do
    duplicate = Enum.find(entries, fn {_path, sizes} -> length(sizes) > 1 end)
    expanded_bytes = entries |> Map.values() |> List.flatten() |> Enum.sum()

    cond do
      duplicate ->
        {path, _sizes} = duplicate
        {:error, {:duplicate_archive_path, path}}

      expanded_bytes > @max_expanded_bytes ->
        {:error, :expanded_archive_too_large}

      not Map.has_key?(entries, "items.json") ->
        {:error, :missing_items_manifest}

      true ->
        :ok
    end
  end

  defp validate_manifest_size(binary) when byte_size(binary) <= @max_manifest_bytes, do: :ok
  defp validate_manifest_size(_binary), do: {:error, :manifest_too_large}

  defp validate_manifest(%{"version" => version, "items" => items})
       when is_integer(version) and version > 0 and is_list(items) do
    {:ok, version, items}
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_items_manifest}

  defp validate_gpx_items(items, entries) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"type" => "GPX", "file" => path} = item, position}, {:ok, acc}
      when is_binary(path) ->
        with {:ok, normalized} <- normalize_path(path),
             {:ok, sizes} <- fetch_entry(entries, normalized),
             :ok <- validate_entry_size(hd(sizes)) do
          normalized_item =
            item
            |> Map.put("archive_path", normalized)
            |> Map.put("position", position)

          {:cont, {:ok, [normalized_item | acc]}}
        else
          {:error, reason} -> {:halt, {:error, {:invalid_gpx_item, path, reason}}}
        end

      {%{"type" => "GPX"} = item, _position}, _acc ->
        {:halt, {:error, {:invalid_gpx_item, Map.get(item, "file"), :missing_file}}}

      {_other, _position}, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
    |> case do
      {:ok, []} ->
        {:error, :no_gpx_items}

      {:ok, gpx_items} when length(gpx_items) > @max_gpx_items ->
        {:error, :too_many_gpx_items}

      {:ok, gpx_items} ->
        paths = Enum.map(gpx_items, & &1["archive_path"])

        if length(paths) == length(Enum.uniq(paths)) do
          {:ok, Enum.reverse(gpx_items)}
        else
          {:error, :duplicate_manifest_paths}
        end

      error ->
        error
    end
  end

  defp fetch_entry(entries, path) do
    case Map.fetch(entries, path) do
      {:ok, sizes} -> {:ok, sizes}
      :error -> {:error, :missing_archive_entry}
    end
  end

  defp validate_entry_size(size) when size <= @max_entry_bytes, do: :ok
  defp validate_entry_size(_size), do: {:error, :gpx_entry_too_large}

  defp normalize_path(path) do
    normalized = String.trim_leading(path, "/")
    segments = String.split(normalized, "/", trim: true)

    cond do
      normalized == "" -> {:error, :empty_path}
      String.contains?(normalized, ["\\", <<0>>]) -> {:error, :unsafe_path}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :unsafe_path}
      Path.type(normalized) == :absolute -> {:error, :unsafe_path}
      true -> {:ok, Enum.join(segments, "/")}
    end
  end

  defp read_entry(handle, path) do
    case :zip.zip_get(String.to_charlist(path), handle) do
      {:ok, {_name, binary}} when is_binary(binary) -> {:ok, binary}
      {:error, reason} -> {:error, {:archive_read_failed, path, reason}}
    end
  end
end
