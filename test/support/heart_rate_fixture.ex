defmodule TrackAnalyzer.HeartRateFixture do
  @moduledoc false
  alias TrackAnalyzer.{Repo, Tracks}
  alias TrackAnalyzer.Tracks.{Analyzer, Track}

  def insert_track!(options \\ []) do
    id = System.unique_integer([:positive])
    start = Keyword.get(options, :started_at, ~U[2026-01-01 08:00:00.000000Z])

    points =
      for index <- 0..120 do
        hr = if Keyword.get(options, :hr, true), do: 110 + div(index, 10), else: nil

        %{
          latitude: 55.0 + index * 0.00025,
          longitude: 12.0,
          elevation_m: 10.0,
          recorded_at: DateTime.add(start, index * 6),
          hdop: 1.0,
          recorded_speed_mps: 4.6,
          heart_rate_bpm: hr,
          extras: if(hr, do: %{"hr" => to_string(hr)}, else: %{}),
          track_position: 0,
          segment_position: 0
        }
      end

    parsed = %{
      name: "Synthetic HR #{id}",
      creator: "Test",
      activity_type: "cycling",
      points: points,
      segments: [%{track_position: 0, position: 0}],
      invalid_point_count: 0,
      warnings: []
    }

    result = Analyzer.analyze(parsed)

    track =
      %Track{}
      |> Track.changeset(%{
        sha256: "synthetic-hr-#{id}",
        original_path: "/tmp/synthetic-hr-#{id}.gpx",
        source_filename: "synthetic-hr.gpx",
        name: parsed.name
      })
      |> Repo.insert!()

    {:ok, track} = Tracks.persist_analysis(track, result)
    track
  end
end
