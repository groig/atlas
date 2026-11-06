defmodule TrackAnalyzer.Repo.Migrations.ReplaceShortEffortsWith1kmAnd5km do
  use Ecto.Migration

  # 100 m and 500 m efforts were too short to survive GPS noise. Both values are
  # derived from the stored source files, so reanalysis recomputes the new ones.
  def change do
    alter table(:tracks) do
      add :best_1km_speed_mps, :float
      add :best_5km_speed_mps, :float
      remove :best_100m_speed_mps, :float
      remove :best_500m_speed_mps, :float
    end
  end
end
