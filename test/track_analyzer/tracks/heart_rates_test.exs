defmodule TrackAnalyzer.Tracks.HeartRatesTest do
  use TrackAnalyzer.DataCase, async: true
  alias TrackAnalyzer.HeartRateFixture
  alias TrackAnalyzer.Tracks.{HeartRates, Track, Point}

  test "persists readings and calculates interval statistics from original points" do
    track = HeartRateFixture.insert_track!()

    assert Repo.aggregate(
             from(p in Point, where: p.track_id == ^track.id and not is_nil(p.heart_rate_bpm)),
             :count
           ) == 121

    assert {:ok, result} = HeartRates.selection(track, 60, 180)
    assert result["covered_s"] == 120
    assert result["average_bpm"] > 110
    assert result["distance_m"] > 500
    assert {:error, :invalid_range} = HeartRates.selection(track, 180, 60)
    assert {:error, :invalid_range} = HeartRates.selection(track, -1, 60)
    assert {:error, :invalid_range} = HeartRates.selection(track, 0, 999_999)
  end

  test "validates explicit profiles and recalibrates existing history without GPX access" do
    track = HeartRateFixture.insert_track!()
    no_hr = HeartRateFixture.insert_track!(hr: false)
    assert {:error, _} = HeartRates.save_profile(%{"mode" => "maximum", "maximum" => "0"})

    assert {:error, _} =
             HeartRates.save_profile(%{
               "mode" => "custom",
               "z1" => "30",
               "z2" => "120",
               "z3" => "100",
               "z4" => "160",
               "z5" => "180"
             })

    assert {:ok, profile} = HeartRates.save_profile(%{"mode" => "maximum", "maximum" => "180"})
    assert profile["edges"] == [30, 108, 126, 144, 162]
    assert HeartRates.pending_count() == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert :ok = TrackAnalyzer.Workers.RecalibrateHeartRateWorker.perform(%Oban.Job{})
    updated = Repo.get!(Track, track.id)
    assert updated.stats["heart_rate"]["load"] > 0
    assert updated.stats["heart_rate"]["zone_revision"] == profile["revision"]
    assert HeartRates.pending_count() == 0
    assert updated.stats["loop_score"] == track.stats["loop_score"]
    assert Repo.get!(Track, no_hr.id).stats["heart_rate"]["load"] == nil
    assert {:ok, _} = HeartRates.save_profile(%{"mode" => "none"})
    assert :ok = HeartRates.recalibrate()
    assert Repo.get!(Track, track.id).stats["heart_rate"]["load"] == nil
  end

  test "same-route comparisons reject reverse directions and mismatched activities" do
    first = HeartRateFixture.insert_track!() |> Repo.preload(:renderings)

    second =
      HeartRateFixture.insert_track!(started_at: ~U[2026-01-02 08:00:00.000000Z])
      |> Repo.preload(:renderings)

    cluster = fn second ->
      %{representative_track: first, memberships: [%{track: first}, %{track: second}]}
    end

    assert TrackAnalyzer.Tracks.HeartRateProgress.summarize(cluster.(second)).pair.available

    reversed = %{
      second
      | renderings:
          Enum.map(second.renderings, fn r ->
            %{
              r
              | encoded_polyline:
                  r.encoded_polyline |> Polyline.decode() |> Enum.reverse() |> Polyline.encode()
            }
          end)
    }

    refute TrackAnalyzer.Tracks.HeartRateProgress.summarize(cluster.(reversed)).pair.available

    refute TrackAnalyzer.Tracks.HeartRateProgress.summarize(
             cluster.(%{second | activity_type: "running"})
           ).pair.available
  end

  test "summaries count only HR recordings and do not turn empty load windows into zeros" do
    HeartRateFixture.insert_track!()
    HeartRateFixture.insert_track!(hr: false)
    summary = HeartRates.overview(~D[2026-01-01])
    assert summary.count == 1
    assert summary.covered_s == 720
    assert summary.load_7 == nil
    assert {:ok, _} = HeartRates.save_profile(%{"mode" => "maximum", "maximum" => "180"})
    assert HeartRates.overview(~D[2026-01-02]).load_7 > 0
    assert HeartRates.overview(~D[2026-03-01]).load_7 == nil
    assert HeartRates.overview(~D[2026-03-01]).load_28 == nil
  end

  test "weekly history sorts across years and represents empty weeks as unavailable" do
    HeartRateFixture.insert_track!(started_at: ~U[2025-12-24 08:00:00.000000Z])
    HeartRateFixture.insert_track!(started_at: ~U[2026-01-07 08:00:00.000000Z])
    weeks = HeartRates.overview(~D[2026-01-10]).weeks
    assert Enum.map(weeks, & &1["week"]) == ["2025-12-22", "2025-12-29", "2026-01-05"]
    assert Enum.at(weeks, 1)["covered_s"] == nil
  end
end
