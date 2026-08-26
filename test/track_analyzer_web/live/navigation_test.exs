defmodule TrackAnalyzerWeb.NavigationTest do
  use TrackAnalyzerWeb.ConnCase, async: true

  alias TrackAnalyzer.Repo
  alias TrackAnalyzer.Tracks.{Analyzer, Rendering, Track}

  test "overview renders the portfolio shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard-summary")
    assert has_element?(view, "#latest-analyzed-track-empty")
    assert has_element?(view, "#library-date-span")
    assert has_element?(view, "#analyzer-state")
    assert has_element?(view, "#portfolio-metrics")
    assert has_element?(view, "#primary-navigation")
  end

  test "overview links each record and latest analysis to its source track", %{conn: conn} do
    record_100m =
      insert_track!(0, %{
        best_100m_speed_mps: 16.0,
        best_500m_speed_mps: 7.0,
        max_speed_mps: 12.0
      })

    instantaneous =
      insert_track!(1, %{
        best_100m_speed_mps: 8.0,
        best_500m_speed_mps: 6.0,
        max_speed_mps: 20.0
      })

    record_500m =
      insert_track!(2, %{
        best_100m_speed_mps: 9.0,
        best_500m_speed_mps: 14.0,
        max_speed_mps: 13.0
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#latest-analyzed-track[href='/tracks/#{record_500m.id}']")
    assert has_element?(view, "#dashboard-record-100m[href='/tracks/#{record_100m.id}']")
    assert has_element?(view, "#dashboard-record-500m[href='/tracks/#{record_500m.id}']")

    assert has_element?(
             view,
             "#dashboard-record-instantaneous[href='/tracks/#{instantaneous.id}']"
           )

    assert has_element?(view, "#speed-history-link[href='/speed']")
  end

  test "overview opens the aggregate recap story maker", %{conn: conn} do
    _track = insert_track!(0, %{distance_m: 12_000.0, moving_s: 2_400.0})

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#share-recap-dialog")

    view |> element("#open-share-recap") |> render_click()

    assert has_element?(view, "#share-recap-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#share-card-canvas[width='1080'][height='1920']")
    assert has_element?(view, "#share-period-all[data-share-period='all']")
    assert has_element?(view, "#share-period-year[aria-pressed='true']")
    assert has_element?(view, "#share-period-month[data-share-period='month']")
    assert has_element?(view, "#share-period-week[data-share-period='week']")
    assert has_element?(view, "#share-recap-share[disabled]")
    assert has_element?(view, "#share-recap-download[disabled]")

    view |> element("#close-share-recap") |> render_click()
    refute has_element?(view, "#share-recap-dialog")
  end

  test "OSF import exposes a dedicated dropzone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")
    assert has_element?(view, "#osf-upload-form")
    assert has_element?(view, "#osf-dropzone")
    assert has_element?(view, "#finish-import")
  end

  test "track library and explore views include stable collection containers", %{conn: conn} do
    {:ok, tracks, _html} = live(conn, ~p"/tracks")
    assert has_element?(tracks, "#track-filter-form")
    assert has_element?(tracks, "#track-library")

    {:ok, explore, _html} = live(conn, ~p"/explore")
    assert has_element?(explore, "#explore-page")
    assert has_element?(explore, "#explore-leaders")
  end

  test "compare picker marks tracks as they are selected and removed", %{conn: conn} do
    track = insert_track!(0, %{})
    selector = "#compare-candidates button[phx-value-id='#{track.id}']"

    {:ok, view, _html} = live(conn, ~p"/compare")
    assert has_element?(view, "#{selector}[aria-pressed='false']")

    view |> element(selector) |> render_click()

    assert_patch(view, ~p"/compare?#{[ids: track.id]}")
    assert has_element?(view, "#{selector}[aria-pressed='true']")
    assert has_element?(view, "#remove-compare-#{track.id}")

    view |> element(selector) |> render_click()

    assert_patch(view, ~p"/compare")
    assert has_element?(view, "#{selector}[aria-pressed='false']")
    refute has_element?(view, "#remove-compare-#{track.id}")
  end

  test "track detail exposes aligned map and profile interaction surfaces", %{conn: conn} do
    track = insert_track!(0, %{})
    insert_rendering!(track)

    {:ok, view, _html} = live(conn, ~p"/tracks/#{track.id}")

    assert has_element?(view, "#track-map[data-polyline]")
    assert has_element?(view, "#track-profile-chart[data-series]")
    assert has_element?(view, "#track-map-instructions")
  end

  test "speed lab exposes historical controls and an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/speed")
    assert has_element?(view, "#speed-lab")
    assert has_element?(view, "#speed-records")
    assert has_element?(view, "#speed-filters")
    assert has_element?(view, "#speed-history-empty")
    assert has_element?(view, "#speed-leaders")
  end

  test "speed record cards link to their source tracks while the trend stays static", %{
    conn: conn
  } do
    record_100m =
      insert_track!(0, %{
        best_100m_speed_mps: 16.0,
        best_500m_speed_mps: 7.0,
        max_speed_mps: 12.0
      })

    instantaneous =
      insert_track!(1, %{
        best_100m_speed_mps: 8.0,
        best_500m_speed_mps: 6.0,
        max_speed_mps: 20.0
      })

    record_500m =
      insert_track!(2, %{
        best_100m_speed_mps: 9.0,
        best_500m_speed_mps: 14.0,
        max_speed_mps: 13.0
      })

    {:ok, view, _html} = live(conn, ~p"/speed")

    assert has_element?(view, "#record-100m[href='/tracks/#{record_100m.id}']")
    assert has_element?(view, "#record-instantaneous[href='/tracks/#{instantaneous.id}']")
    assert has_element?(view, "#record-500m[href='/tracks/#{record_500m.id}']")
    assert has_element?(view, "article#speed-trend")
    refute has_element?(view, "#speed-trend[href]")
  end

  test "page headers avoid redundant global actions", %{conn: conn} do
    track = insert_track!(0, %{})

    {:ok, overview, _html} = live(conn, ~p"/")
    refute has_element?(overview, "#dashboard-summary a[href='/import']")
    refute has_element?(overview, "#dashboard-summary a[href='/explore']")
    assert has_element?(overview, "#nav-import[href='/import']")
    assert has_element?(overview, "#mobile-import[href='/import']")

    {:ok, tracks, _html} = live(conn, ~p"/tracks")
    refute has_element?(tracks, "#tracks-header a[href='/import']")
    refute has_element?(tracks, "#tracks-header a[href='/compare']")

    {:ok, explore, _html} = live(conn, ~p"/explore")
    refute has_element?(explore, "#explore-leaderboard-header a[href='/compare']")

    {:ok, detail, _html} = live(conn, ~p"/tracks/#{track.id}")
    refute has_element?(detail, "#track-actions a[href='/speed']")
    assert has_element?(detail, "#track-actions a[href='/compare?ids=#{track.id}']")
    assert has_element?(detail, "#reanalyze-track")
  end

  defp insert_track!(index, overrides) do
    defaults = %{
      sha256: "navigation-#{System.unique_integer([:positive])}-#{index}",
      original_path: "/tmp/navigation-#{index}.gpx",
      source_filename: "navigation-#{index}.gpx",
      source_folder: "tracks/test",
      name: "Test track #{index}",
      status: "complete",
      stage: "Ready to explore",
      progress: 100,
      analysis_version: Analyzer.analysis_version(),
      started_at: DateTime.add(~U[2025-01-01 08:00:00Z], index, :day),
      ended_at: DateTime.add(~U[2025-01-01 09:00:00Z], index, :day),
      point_count: 10,
      max_speed_mps: 10.0,
      best_100m_speed_mps: 8.0,
      best_500m_speed_mps: 6.0,
      max_speed_confidence: "high"
    }

    %Track{}
    |> Track.changeset(Map.merge(defaults, overrides))
    |> Repo.insert!()
  end

  defp insert_rendering!(track) do
    points = [{12.56, 55.67}, {12.57, 55.68}, {12.58, 55.69}]

    %Rendering{
      track_id: track.id,
      level: "detail",
      point_count: length(points),
      encoded_polyline: Polyline.encode(points),
      series: %{
        "distance_km" => [0.0, 0.2, 0.4],
        "elevation_m" => [10.0, 12.0, 11.0],
        "speed_kmh" => [18.0, 22.0, 20.0],
        "grade_percent" => [0.0, 1.0, -0.5],
        "time" => ["2025-01-01T08:00:00Z", "2025-01-01T08:01:00Z", "2025-01-01T08:02:00Z"]
      }
    }
    |> Repo.insert!()
  end
end
