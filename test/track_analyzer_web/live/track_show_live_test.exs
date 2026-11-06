defmodule TrackAnalyzerWeb.TrackShowLiveTest do
  use TrackAnalyzerWeb.ConnCase, async: true

  alias TrackAnalyzer.FITFixture

  test "a ride whose HR locked onto cadence shows a small indicator", %{conn: conn} do
    locked =
      FITFixture.insert_track!(
        count: 240,
        cadence: fn _index -> 85 end,
        heart_rate: fn index -> if index in 60..160, do: 86, else: 140 end
      )

    {:ok, view, _html} = live(conn, ~p"/tracks/#{locked.id}")
    assert has_element?(view, "#track-hr-cadence-lock")
    assert locked.stats["heart_rate"]["maximum_bpm"] == 140.0
  end

  test "an ordinary ride has no cadence lock indicator", %{conn: conn} do
    track = FITFixture.insert_track!(count: 240, heart_rate: fn _index -> 140 end)

    {:ok, view, _html} = live(conn, ~p"/tracks/#{track.id}")
    assert has_element?(view, "#track-heart-rate")
    refute has_element?(view, "#track-hr-cadence-lock")
  end
end
