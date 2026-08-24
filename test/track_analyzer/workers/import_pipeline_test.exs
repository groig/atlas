defmodule TrackAnalyzer.Workers.ImportPipelineTest do
  use TrackAnalyzer.DataCase, async: false

  alias TrackAnalyzer.{Imports, TrackFixture, Tracks}
  alias TrackAnalyzer.Workers.{AnalyzeTrackWorker, ArchiveWorker}

  @tag :tmp_dir
  test "imports, analyzes, and reports an OSF track end to end", %{tmp_dir: directory} do
    path = TrackFixture.write_osf!(directory)
    {:ok, batch} = Imports.create_batch()
    {:ok, archive} = Imports.accept_archive(batch, path, "fixture.osf")

    assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    [track] = Tracks.list_tracks()
    assert :ok = AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})

    track = Tracks.get_track!(track.id)
    archive = Imports.get_archive!(archive.id)

    assert track.status == "complete"
    assert track.point_count == 3
    assert track.distance_m > 250
    assert archive.status == "complete"
    assert archive.progress == 100
    assert archive.complete_count == 1
  end

  @tag :tmp_dir
  test "deduplicates the same GPX across separate OSF exports", %{tmp_dir: directory} do
    path = TrackFixture.write_osf!(directory)

    for filename <- ["first.osf", "second.osf"] do
      {:ok, batch} = Imports.create_batch()
      {:ok, archive} = Imports.accept_archive(batch, path, filename)
      assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    end

    assert [_track] = Tracks.list_tracks()
    assert Imports.list_recent_archives(2) |> Enum.map(& &1.duplicate_count) |> Enum.sum() == 1
  end
end
