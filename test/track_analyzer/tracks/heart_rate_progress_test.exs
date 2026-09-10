defmodule TrackAnalyzer.Tracks.HeartRateProgressTest do
  use ExUnit.Case, async: true
  alias TrackAnalyzer.Tracks.{HeartRateProgress, Track}

  defp attempt(index, bpm, speed \\ 20) do
    %{
      track: %Track{
        id: index + 1,
        name: "Synthetic #{index}",
        started_at: DateTime.add(~U[2026-01-01 00:00:00Z], index * 3, :day)
      },
      sectors:
        Map.new(10..30, fn i ->
          {i,
           %{
             "average_bpm" => bpm,
             "speed_kmh" => speed,
             "eligible_s" => 12,
             "moving_s" => 12,
             "start_s" => i * 12 + 300,
             "end_s" => (i + 1) * 12 + 300
           }}
        end)
    }
  end

  test "describes HR changes at similar speed without claiming fitness" do
    pair = HeartRateProgress.compare([attempt(0, 145), attempt(1, 135)])
    assert pair.available
    assert pair.label == "Lower HR at similar speed"
    assert pair.before_id == 1 and pair.after_id == 2
    assert pair.support_s == 252
    assert pair.hr_delta == -10
  end

  test "separates speed at similar effort from both metrics changing" do
    assert HeartRateProgress.compare([attempt(0, 130, 20), attempt(1, 132, 23)]).label ==
             "Faster at similar HR"

    assert HeartRateProgress.compare([attempt(0, 130, 20), attempt(1, 150, 23)]).label ==
             "Different effort — not comparable"
  end

  test "rejects insufficient shared sectors and waits for six attempts over two weeks" do
    a = attempt(0, 140)
    b = %{attempt(1, 130) | sectors: Map.take(a.sectors, [10, 11])}
    refute HeartRateProgress.compare([a, b]).available
    refute HeartRateProgress.trend([a, b]).available
    six = for i <- 0..5, do: attempt(i, if(i < 3, do: 145, else: 130))
    assert HeartRateProgress.trend(six).label == "Lower HR at similar speed"
    same_week = Enum.map(six, &put_in(&1.track.started_at, ~U[2026-01-01 00:00:00Z]))
    refute HeartRateProgress.trend(same_week).available
  end

  test "observed variation can suppress a small apparent improvement" do
    attempts =
      [120, 140, 160, 115, 135, 155]
      |> Enum.with_index()
      |> Enum.map(fn {hr, i} -> attempt(i, hr) end)

    assert HeartRateProgress.trend(attempts).label == "No clear change"
    assert HeartRateProgress.trend(attempts).hr_noise == 40
  end
end
