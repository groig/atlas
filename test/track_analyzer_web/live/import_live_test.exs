defmodule TrackAnalyzerWeb.ImportLiveTest do
  use TrackAnalyzerWeb.ConnCase, async: false

  alias TrackAnalyzer.Imports
  alias TrackAnalyzer.Workers.{AnalyzeTrackWorker, ArchiveWorker}

  @tag :tmp_dir
  test "the import log lists skipped files with their reason", %{conn: conn, tmp_dir: dir} do
    path = Path.join(dir, "single-point.gpx")

    File.write!(path, """
    <gpx version="1.1"><trk><trkseg>
      <trkpt lat="55.6761" lon="12.5683"><time>2026-04-06T12:55:00Z</time></trkpt>
    </trkseg></trk></gpx>
    """)

    {:ok, batch} = Imports.create_batch()
    {:ok, archive} = Imports.accept_archive(batch, path, "single-point.gpx")
    :ok = ArchiveWorker.perform(%Oban.Job{args: %{"archive_id" => archive.id}})
    [track] = TrackAnalyzer.Tracks.list_tracks()
    :ok = AnalyzeTrackWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#archives-#{archive.id}-skipped")
    assert has_element?(view, "#archives-#{archive.id}-skipped li", "only 1 point")
  end
end
