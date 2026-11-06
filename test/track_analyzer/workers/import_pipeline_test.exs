defmodule TrackAnalyzer.Workers.ImportPipelineTest do
  use TrackAnalyzer.DataCase, async: false

  alias TrackAnalyzer.{FITFixture, Imports, TrackFixture, Tracks}
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
    assert track.point_count == 12
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

  @tag :tmp_dir
  test "imports a standalone GPX file as a one-track upload", %{tmp_dir: directory} do
    path = TrackFixture.write_gpx!(directory)
    {:ok, batch} = Imports.create_batch()
    {:ok, archive} = Imports.accept_archive(batch, path, "Morning Loop.GPX")
    assert archive.format == "gpx"
    assert archive.storage_path =~ ~r/\.gpx$/

    assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    [track] = Tracks.list_tracks()
    assert track.source_format == "gpx"
    assert track.source_folder == nil
    assert :ok = AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})

    assert Tracks.get_track!(track.id).status == "complete"
    assert Imports.get_archive!(archive.id).status == "complete"
  end

  @tag :tmp_dir
  test "imports a FIT file with its cadence and speed sensor data", %{tmp_dir: directory} do
    path = FITFixture.write!(directory, "ride-0-2026-05-01.fit")
    {:ok, batch} = Imports.create_batch()
    {:ok, archive} = Imports.accept_archive(batch, path, "ride-0-2026-05-01.fit")
    assert archive.format == "fit"

    assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    [track] = Tracks.list_tracks()
    assert track.source_format == "fit"
    assert track.original_path =~ ~r/\.fit$/
    assert :ok = AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})

    track = Tracks.get_track!(track.id)
    assert track.status == "complete"
    assert track.name == "ride-0-2026-05-01"
    assert track.activity_type == "road_cycling"
    assert track.point_count == 120
    assert track.stats["cadence"]["average_rpm"] == 85.0
    assert track.stats["speed_sensor"]["distance_source"] == "device"

    [point | _] =
      TrackAnalyzer.Repo.all(
        from point in TrackAnalyzer.Tracks.Point,
          where: point.track_id == ^track.id,
          order_by: point.position
      )

    assert point.cadence_rpm == 85.0
    assert_in_delta point.sensor_speed_mps, 6.12, 0.001

    # The same file uploaded again is a duplicate, not a second ride.
    {:ok, batch} = Imports.create_batch()
    {:ok, again} = Imports.accept_archive(batch, path, "copy.fit")
    assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => again.id}})
    assert [_track] = Tracks.list_tracks()
    assert Imports.get_archive!(again.id).duplicate_count == 1
  end

  @tag :tmp_dir
  test "rejects unsupported uploads and files whose content does not match", %{
    tmp_dir: directory
  } do
    {:ok, batch} = Imports.create_batch()
    text = Path.join(directory, "notes.txt")
    File.write!(text, "hello")
    assert {:error, :unsupported_file_type} = Imports.accept_archive(batch, text, "notes.txt")

    gpx = TrackFixture.write_gpx!(directory)
    {:ok, archive} = Imports.accept_archive(batch, gpx, "renamed.fit")

    assert {:discard, _reason} =
             ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})

    archive = Imports.get_archive!(archive.id)
    assert archive.status == "failed"
    assert archive.error =~ "not_a_fit_file"
  end

  @tag :tmp_dir
  test "near-empty tracks are skipped, kept out of totals, and listed in the import log", %{
    tmp_dir: directory
  } do
    # Three fixes, about 80 m: a recording started by accident.
    short = Path.join(directory, "accidental.gpx")

    File.write!(short, """
    <gpx version="1.1" creator="OsmAnd"><trk><trkseg>
      <trkpt lat="55.6761" lon="12.5683"><time>2026-09-30T20:59:00Z</time></trkpt>
      <trkpt lat="55.6765" lon="12.5683"><time>2026-09-30T21:00:00Z</time></trkpt>
      <trkpt lat="55.6768" lon="12.5683"><time>2026-09-30T21:01:00Z</time></trkpt>
    </trkseg></trk></gpx>
    """)

    {:ok, batch} = Imports.create_batch()
    {:ok, archive} = Imports.accept_archive(batch, short, "accidental.gpx")
    assert :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    [track] = Tracks.list_tracks()
    assert :ok = AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})

    track = Tracks.get_track!(track.id)
    assert track.status == "insufficient_data"
    assert track.stage == "Skipped: only 3 points"
    assert track.quality["skip_reason"] == "only 3 points"

    archive = Imports.get_archive!(archive.id)
    assert archive.status == "complete"
    assert archive.complete_count == 0

    assert [%{skipped: [%{path: path, reason: "only 3 points"}]}] =
             Imports.list_recent_archives(1)

    assert path =~ "accidental.gpx"
    assert %{track_count: 0, distance_m: 0, activity: []} = Tracks.share_summary(:all)
    assert Tracks.portfolio_summary().track_count == 0
  end
end
