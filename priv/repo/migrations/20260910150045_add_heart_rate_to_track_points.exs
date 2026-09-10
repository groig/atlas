defmodule TrackAnalyzer.Repo.Migrations.AddHeartRateToTrackPoints do
  use Ecto.Migration

  def change do
    alter table(:track_points) do
      add :heart_rate_bpm, :float
    end
  end
end
