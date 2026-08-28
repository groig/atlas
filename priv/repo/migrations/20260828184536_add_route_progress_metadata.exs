defmodule TrackAnalyzer.Repo.Migrations.AddRouteProgressMetadata do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :activity_type, :string
    end

    create index(:tracks, [:activity_type])

    alter table(:route_clusters) do
      add :representative_track_id, references(:tracks, on_delete: :nilify_all)
      add :activity_type, :string
      add :matcher_version, :integer, null: false, default: 1
    end

    create index(:route_clusters, [:representative_track_id])
    create index(:route_clusters, [:activity_type])

    alter table(:route_cluster_memberships) do
      add :metrics, :map, null: false, default: %{}
    end
  end
end
