defmodule TrackAnalyzer.Repo.Migrations.AddSpeedHistoryMetricsToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :best_100m_speed_mps, :float
      add :best_500m_speed_mps, :float
      add :max_speed_confidence, :string
      add :max_speed_point_position, :integer
    end

    create index(:tracks, [:best_100m_speed_mps])
    create index(:tracks, [:best_500m_speed_mps])

    create constraint(:tracks, :tracks_max_speed_confidence_values,
             check:
               "max_speed_confidence IS NULL OR max_speed_confidence IN ('high', 'medium', 'low')"
           )
  end
end
