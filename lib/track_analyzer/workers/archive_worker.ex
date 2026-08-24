defmodule TrackAnalyzer.Workers.ArchiveWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :archives,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:archive_id]]

  alias TrackAnalyzer.Imports
  alias TrackAnalyzer.Imports.OSF
  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Storage.Local
  alias TrackAnalyzer.Tracks.Track
  alias TrackAnalyzer.Workers.AnalyzeTrackWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"archive_id" => archive_id}}) do
    archive = Imports.get_archive!(archive_id)

    with {:ok, archive} <-
           Imports.update_archive(archive, %{
             status: "inspecting",
             stage: "Validating OsmAnd export",
             progress: 5,
             error: nil
           }),
         {:ok, inspection} <- OSF.inspect(archive.storage_path),
         {:ok, archive} <-
           Imports.update_archive(archive, %{
             status: "processing",
             stage: "Extracting #{length(inspection.items)} tracks",
             progress: 12,
             manifest_version: inspection.version,
             manifest: inspection.manifest,
             warning: inspection.warning,
             item_count: length(inspection.items)
           }) do
      counts = process_items(archive, inspection.items)

      {:ok, archive} =
        Imports.update_archive(archive, %{
          status: "processing",
          stage: "Analyzing tracks",
          progress: 35,
          new_count: counts.new,
          duplicate_count: counts.duplicate,
          failed_count: counts.failed
        })

      _updated = Imports.recalculate_archive(archive.id)
      :ok
    else
      {:error, reason} -> fail_archive(archive, reason)
    end
  rescue
    error -> fail_archive(Imports.get_archive!(archive_id), error)
  end

  defp process_items(archive, items) do
    Enum.reduce(items, %{new: 0, duplicate: 0, failed: 0}, fn item, counts ->
      case process_item(archive, item) do
        :new -> Map.update!(counts, :new, &(&1 + 1))
        :duplicate -> Map.update!(counts, :duplicate, &(&1 + 1))
        :failed -> Map.update!(counts, :failed, &(&1 + 1))
      end
    end)
  end

  defp process_item(archive, manifest) do
    path = manifest["archive_path"]

    item =
      Imports.get_item_by(archive.id, path) ||
        create_item!(archive, manifest)

    with {:ok, binary} <- OSF.read_gpx(archive.storage_path, path),
         {:ok, stored} <- Local.store_track(binary) do
      case Repo.get_by(Track, sha256: stored.sha256) do
        nil -> create_track(item, manifest, stored)
        track -> link_duplicate(item, track, stored.sha256)
      end
    else
      {:error, reason} ->
        {:ok, _item} = Imports.update_item(item, %{status: "failed", error: error_text(reason)})
        :failed
    end
  end

  defp create_item!(archive, manifest) do
    attrs = %{
      position: manifest["position"],
      path: manifest["archive_path"],
      type: manifest["type"],
      subtype: manifest["subtype"],
      status: "queued",
      manifest: Map.drop(manifest, ["archive_path", "position"])
    }

    case Imports.create_item(archive, attrs) do
      {:ok, item} -> item
      {:error, changeset} -> raise "could not create archive item: #{inspect(changeset.errors)}"
    end
  end

  defp create_track(item, manifest, stored) do
    logical_path = manifest["archive_path"]
    filename = Path.basename(logical_path)

    attrs = %{
      sha256: stored.sha256,
      original_path: stored.storage_path,
      source_filename: filename,
      source_folder: Path.dirname(logical_path),
      name: filename |> Path.rootname() |> String.replace("_", " "),
      status: "queued",
      stage: "Waiting for analyzer",
      manifest_distance_m: number(manifest["total_distance"]),
      manifest_time_ms: integer(manifest["time_span"])
    }

    case %Track{} |> Track.changeset(attrs) |> Repo.insert() do
      {:ok, track} ->
        {:ok, _item} =
          Imports.update_item(item, %{
            track_id: track.id,
            sha256: stored.sha256,
            status: "processing",
            error: nil
          })

        {:ok, _job} = %{track_id: track.id} |> AnalyzeTrackWorker.new() |> Oban.insert()
        :new

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :sha256) do
          track = Repo.get_by!(Track, sha256: stored.sha256)
          link_duplicate(item, track, stored.sha256)
        else
          raise "could not create track: #{inspect(changeset.errors)}"
        end
    end
  end

  defp link_duplicate(item, track, sha256) do
    {:ok, _item} =
      Imports.update_item(item, %{
        track_id: track.id,
        sha256: sha256,
        status: "duplicate",
        error: nil
      })

    if track.status in ["queued", "failed"] do
      {:ok, _job} = %{track_id: track.id} |> AnalyzeTrackWorker.new() |> Oban.insert()
    end

    :duplicate
  end

  defp fail_archive(archive, reason) do
    {:ok, _archive} =
      Imports.update_archive(archive, %{
        status: "failed",
        stage: "Could not read export",
        progress: 100,
        error: error_text(reason)
      })

    {:discard, error_text(reason)}
  end

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_value), do: nil
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(_value), do: nil

  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(reason), do: inspect(reason)
end
