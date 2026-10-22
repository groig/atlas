defmodule TrackAnalyzerWeb.PedalingLiveTest do
  use TrackAnalyzerWeb.ConnCase, async: true

  alias TrackAnalyzer.{FITFixture, HeartRateFixture}

  test "pedaling progress starts with an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/progress/pedaling")
    assert has_element?(view, "#pedaling-empty")
    assert has_element?(view, "#progress-tab-pedaling[aria-current='page']")
    refute has_element?(view, "#pedaling-history-chart")
  end

  test "a sensor ride shows cadence, gearing and calibration on its track page", %{conn: conn} do
    track = FITFixture.insert_track!(count: 240)
    {:ok, view, _html} = live(conn, ~p"/tracks/#{track.id}")

    assert has_element?(view, "#track-sensors")
    assert has_element?(view, "#cadence-stats")
    assert has_element?(view, "#cadence-chart[data-series]")
    assert has_element?(view, "#cadence-axis-distance")
    assert has_element?(view, "#cadence-distribution[data-kind='cadence_bands']")
    assert has_element?(view, "#cadence-development[data-kind='development']")
    assert has_element?(view, "#cadence-terrain-flat")
    assert has_element?(view, "#speed-sensor-check")
    assert has_element?(view, "#speed-sensor-calibration", "smaller")
    assert has_element?(view, "#track-cadence-progress[href='/progress/pedaling']")
  end

  test "rides without sensors keep the regular profile", %{conn: conn} do
    track = HeartRateFixture.insert_track!(hr: false)
    {:ok, view, _html} = live(conn, ~p"/tracks/#{track.id}")
    refute has_element?(view, "#track-sensors")
    assert has_element?(view, "#track-profile-chart")
  end

  test "sensor rides feed progress, the dashboard and comparisons", %{conn: conn} do
    track = FITFixture.insert_track!(count: 240, name: "Wheel sensor loop")
    plain = HeartRateFixture.insert_track!(hr: false)

    {:ok, view, _html} = live(conn, ~p"/progress/pedaling")
    refute has_element?(view, "#pedaling-empty")
    assert has_element?(view, "#pedaling-summary")
    assert has_element?(view, "#pedaling-history-chart")
    assert has_element?(view, "#pedaling-distribution")
    assert has_element?(view, "#pedaling-development")
    assert has_element?(view, "#pedaling-terrain-flat")
    assert has_element?(view, "#pedaling-calibration-chart")
    assert has_element?(view, "#pedaling-tracks a[href='/tracks/#{track.id}']")

    {:ok, home, _html} = live(conn, ~p"/")
    assert has_element?(home, "#dashboard-pedaling[href='/progress/pedaling']")

    {:ok, compare, _html} = live(conn, ~p"/compare?#{[ids: "#{track.id},#{plain.id}"]}")
    assert has_element?(compare, "#compare-cadence-#{track.id}")
    assert has_element?(compare, "#compare-cadence-#{plain.id}", "Unavailable")
  end

  test "the import page accepts GPX and FIT alongside OSF", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    upload =
      file_input(view, "#track-upload-form", :archives, [
        %{name: "ride.fit", content: FITFixture.binary(), type: "application/octet-stream"}
      ])

    assert render_upload(upload, "ride.fit") =~ "ride.fit"
    assert has_element?(view, "#import-archives [id$='-format']", "fit")
  end
end
