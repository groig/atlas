defmodule TrackAnalyzer.Imports do
  @moduledoc """
  Owns OSF upload batches and their live, persisted processing state.
  """

  import Ecto.Query

  alias TrackAnalyzer.Imports.{ArchiveItem, ImportBatch, SourceArchive}
  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Storage.Local

  @topic "imports"

  def subscribe, do: Phoenix.PubSub.subscribe(TrackAnalyzer.PubSub, @topic)

  def create_batch do
    %ImportBatch{}
    |> ImportBatch.changeset(%{status: "uploading"})
    |> Repo.insert()
  end

  def finish_upload(%ImportBatch{} = batch) do
    batch = get_batch!(batch.id)
    status = if batch.archive_count == 0, do: "failed", else: "processing"

    with {:ok, updated} <- batch |> ImportBatch.changeset(%{status: status}) |> Repo.update() do
      broadcast(:batch_updated, updated)
      {:ok, recalculate_batch(updated.id)}
    end
  end

  def accept_archive(%ImportBatch{} = batch, uploaded_path, client_name) do
    with {:ok, stored} <- Local.store_archive(uploaded_path, client_name),
         {:ok, archive} <-
           %SourceArchive{}
           |> SourceArchive.changeset(Map.put(stored, :import_batch_id, batch.id))
           |> Repo.insert(),
         {:ok, _job} <-
           %{archive_id: archive.id}
           |> TrackAnalyzer.Workers.ArchiveWorker.new()
           |> Oban.insert() do
      recalculate_batch(batch.id)
      broadcast(:archive_updated, archive)
      {:ok, archive}
    end
  end

  def list_recent_archives(limit \\ 20) do
    SourceArchive
    |> order_by([archive], desc: archive.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_batches(limit \\ 10) do
    ImportBatch
    |> order_by([batch], desc: batch.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_archive!(id), do: Repo.get!(SourceArchive, id)
  def get_batch!(id), do: Repo.get!(ImportBatch, id)

  def get_item_by(archive_id, path) do
    Repo.get_by(ArchiveItem, source_archive_id: archive_id, path: path)
  end

  def update_archive(%SourceArchive{} = archive, attrs) do
    archive
    |> SourceArchive.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} = result ->
        recalculate_batch(updated.import_batch_id)
        broadcast(:archive_updated, updated)
        result

      error ->
        error
    end
  end

  def create_item(%SourceArchive{} = archive, attrs) do
    attrs = Map.put(attrs, :source_archive_id, archive.id)

    %ArchiveItem{}
    |> ArchiveItem.changeset(attrs)
    |> Repo.insert()
  end

  def update_item(%ArchiveItem{} = item, attrs) do
    item
    |> ArchiveItem.changeset(attrs)
    |> Repo.update()
  end

  def mark_track_items(track_id, status, error \\ nil) do
    now = DateTime.utc_now()

    archive_ids =
      ArchiveItem
      |> where([item], item.track_id == ^track_id)
      |> select([item], item.source_archive_id)
      |> distinct(true)
      |> Repo.all()

    ArchiveItem
    |> where([item], item.track_id == ^track_id)
    |> Repo.update_all(set: [status: status, error: error, updated_at: now])

    Enum.each(archive_ids, &recalculate_archive/1)
    :ok
  end

  def recalculate_archive(archive_id) do
    counts =
      ArchiveItem
      |> where([item], item.source_archive_id == ^archive_id)
      |> group_by([item], item.status)
      |> select([item], {item.status, count(item.id)})
      |> Repo.all()
      |> Map.new()

    archive = get_archive!(archive_id)
    item_count = max(archive.item_count, Enum.sum(Map.values(counts)))

    complete_count =
      Enum.sum(
        for status <- ~w(complete duplicate insufficient_data), do: Map.get(counts, status, 0)
      )

    failed_count = Map.get(counts, "failed", 0)
    duplicate_count = Map.get(counts, "duplicate", 0)
    done_count = complete_count + failed_count

    {status, stage} =
      cond do
        item_count == 0 and archive.status in ~w(failed complete) ->
          {archive.status, archive.stage}

        item_count == 0 ->
          {"processing", "Reading archive"}

        done_count < item_count ->
          {"processing", "Analyzing tracks"}

        failed_count == item_count ->
          {"failed", "Import failed"}

        failed_count > 0 ->
          {"partial", "Completed with issues"}

        true ->
          {"complete", "Ready to explore"}
      end

    progress =
      if item_count > 0,
        do: min(100, 35 + round(done_count / item_count * 65)),
        else: archive.progress

    {:ok, updated} =
      update_archive(archive, %{
        status: status,
        stage: stage,
        progress: progress,
        complete_count: complete_count,
        duplicate_count: duplicate_count,
        failed_count: failed_count
      })

    updated
  end

  def recalculate_batch(nil), do: nil

  def recalculate_batch(batch_id) do
    archives =
      Repo.all(from archive in SourceArchive, where: archive.import_batch_id == ^batch_id)

    batch = get_batch!(batch_id)
    terminal = ~w(complete partial failed duplicate)
    complete? = archives != [] and Enum.all?(archives, &(&1.status in terminal))
    failed_count = Enum.sum(Enum.map(archives, & &1.failed_count))

    status =
      cond do
        batch.status == "uploading" -> "uploading"
        not complete? -> "processing"
        failed_count > 0 -> "partial"
        true -> "complete"
      end

    attrs = %{
      status: status,
      archive_count: length(archives),
      item_count: Enum.sum(Enum.map(archives, & &1.item_count)),
      complete_count: Enum.sum(Enum.map(archives, & &1.complete_count)),
      duplicate_count: Enum.sum(Enum.map(archives, & &1.duplicate_count)),
      failed_count: failed_count
    }

    {:ok, updated} = batch |> ImportBatch.changeset(attrs) |> Repo.update()
    broadcast(:batch_updated, updated)
    updated
  end

  defp broadcast(event, value) do
    Phoenix.PubSub.broadcast(TrackAnalyzer.PubSub, @topic, {event, value})
  end
end
