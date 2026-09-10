defmodule TrackAnalyzerWeb.HeartRateLiveTest do
  use TrackAnalyzerWeb.ConnCase, async: true
  alias TrackAnalyzer.HeartRateFixture

  test "HR view starts with absolute BPM and an honest empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/progress/heart-rate")
    assert has_element?(view, "#hr-empty")
    assert has_element?(view, "#progress-tab-heart[aria-current='page']")
    assert has_element?(view, "#hr-profile-form")
    refute has_element?(view, "#hr-load-chart")
  end

  test "HR track exposes aligned charts, intervals, quality and home discovery", %{conn: conn} do
    track = HeartRateFixture.insert_track!()
    {:ok, view, _} = live(conn, ~p"/tracks/#{track.id}")
    assert has_element?(view, "#heart-rate-chart[data-series]")
    assert has_element?(view, "#track-map[data-polyline]")
    refute has_element?(view, "#track-profile-chart")
    assert has_element?(view, "#hr-distribution")
    assert has_element?(view, "#hr-time-above")
    assert has_element?(view, "#hr-quality")
    view |> form("#hr-range-form", range: %{from: "1", until: "3"}) |> render_submit()
    assert has_element?(view, "#hr-selection")
    assert_push_event(view, "hr:selection", %{from: 60.0, until: 180.0})
    view |> element("#hr-range-clear") |> render_click()
    refute has_element?(view, "#hr-selection")
    view |> element("#hr-effort-60") |> render_click()
    assert has_element?(view, "#hr-selection")
    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#dashboard-heart-rate[href='/progress/heart-rate']")
    {:ok, progress, _} = live(conn, ~p"/progress/heart-rate")
    assert has_element?(progress, "#hr-weekly-chart")
    assert has_element?(progress, "#hr-tracks a[href='/tracks/#{track.id}']")
  end

  test "profile settings reveal load only after explicit configuration", %{conn: conn} do
    HeartRateFixture.insert_track!()
    {:ok, view, _} = live(conn, ~p"/progress/heart-rate")
    view |> form("#hr-profile-form", profile: %{mode: "maximum"}) |> render_change()
    assert has_element?(view, "#hr-maximum-fields")

    view
    |> form("#hr-profile-form", profile: %{mode: "maximum", maximum: "180"})
    |> render_submit()

    assert has_element?(view, "#hr-load-chart")
    view |> form("#hr-profile-form", profile: %{mode: "none"}) |> render_submit()
    refute has_element?(view, "#hr-load-chart")
  end

  test "mixed comparisons mark missing heart rate unavailable and retain selection styling", %{
    conn: conn
  } do
    with_hr = HeartRateFixture.insert_track!()
    without = HeartRateFixture.insert_track!(hr: false)
    {:ok, view, _} = live(conn, ~p"/compare?#{[ids: "#{with_hr.id},#{without.id}"]}")
    assert has_element?(view, "#compare-hr-chart")
    assert has_element?(view, "#compare-hr-#{without.id}", "Unavailable")

    assert has_element?(
             view,
             "#compare-candidates button[phx-value-id='#{with_hr.id}'][aria-pressed='true']"
           )

    view |> element("#remove-compare-#{with_hr.id}") |> render_click()
    refute has_element?(view, "#compare-hr-chart")
  end
end
