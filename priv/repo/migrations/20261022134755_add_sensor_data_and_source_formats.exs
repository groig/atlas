defmodule TrackAnalyzer.Repo.Migrations.AddSensorDataAndSourceFormats do
  use Ecto.Migration

  def change do
    alter table(:track_points) do
      add :cadence_rpm, :float
      add :sensor_speed_mps, :float
      add :sensor_distance_m, :float
    end

    alter table(:tracks) do
      add :source_format, :string, null: false, default: "gpx"
    end

    alter table(:source_archives) do
      add :format, :string, null: false, default: "osf"
    end
  end
end
