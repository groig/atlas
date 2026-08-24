defmodule TrackAnalyzer.Repo.Migrations.CreateTrackAnalyzerTables do
  use Ecto.Migration

  def change do
    create table(:import_batches) do
      add :status, :string, null: false, default: "uploading"
      add :archive_count, :integer, null: false, default: 0
      add :item_count, :integer, null: false, default: 0
      add :complete_count, :integer, null: false, default: 0
      add :duplicate_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create table(:source_archives) do
      add :import_batch_id, references(:import_batches, on_delete: :nilify_all)
      add :sha256, :string, null: false
      add :original_filename, :string, null: false
      add :storage_path, :text, null: false
      add :byte_size, :bigint, null: false
      add :manifest_version, :integer
      add :manifest, :map, null: false, default: %{}
      add :status, :string, null: false, default: "queued"
      add :progress, :integer, null: false, default: 0
      add :stage, :string, null: false, default: "Queued"
      add :item_count, :integer, null: false, default: 0
      add :new_count, :integer, null: false, default: 0
      add :duplicate_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :complete_count, :integer, null: false, default: 0
      add :warning, :text
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:source_archives, [:sha256])
    create index(:source_archives, [:import_batch_id])
    create index(:source_archives, [:status])

    create table(:tracks) do
      add :sha256, :string, null: false
      add :original_path, :text, null: false
      add :source_filename, :string, null: false
      add :source_folder, :string
      add :name, :string, null: false
      add :creator, :string
      add :status, :string, null: false, default: "queued"
      add :stage, :string, null: false, default: "Queued"
      add :progress, :integer, null: false, default: 0
      add :analysis_version, :integer, null: false, default: 1
      add :timezone, :string
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :point_count, :integer, null: false, default: 0
      add :segment_count, :integer, null: false, default: 0
      add :distance_m, :float
      add :elapsed_s, :float
      add :moving_s, :float
      add :stopped_s, :float
      add :avg_speed_mps, :float
      add :max_speed_mps, :float
      add :elevation_gain_m, :float
      add :elevation_loss_m, :float
      add :min_elevation_m, :float
      add :max_elevation_m, :float
      add :quality_score, :float
      add :manifest_distance_m, :float
      add :manifest_time_ms, :bigint
      add :bounds, :map, null: false, default: %{}
      add :stats, :map, null: false, default: %{}
      add :quality, :map, null: false, default: %{}
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tracks, [:sha256])
    create index(:tracks, [:status])
    create index(:tracks, [:started_at])
    create index(:tracks, [:distance_m])

    create table(:archive_items) do
      add :source_archive_id, references(:source_archives, on_delete: :delete_all), null: false
      add :track_id, references(:tracks, on_delete: :nilify_all)
      add :position, :integer, null: false
      add :path, :text, null: false
      add :type, :string, null: false
      add :subtype, :string
      add :sha256, :string
      add :status, :string, null: false, default: "queued"
      add :manifest, :map, null: false, default: %{}
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:archive_items, [:source_archive_id, :path])
    create index(:archive_items, [:source_archive_id, :status])
    create index(:archive_items, [:track_id])
    create index(:archive_items, [:sha256])

    create table(:track_segments) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :track_position, :integer, null: false
      add :position, :integer, null: false
      add :name, :string
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :point_count, :integer, null: false, default: 0
      add :distance_m, :float, null: false, default: 0.0
      add :stats, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:track_segments, [:track_id, :track_position, :position])
    create index(:track_segments, [:track_id])

    create table(:track_points) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :track_segment_id, references(:track_segments, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :elevation_m, :float
      add :recorded_at, :utc_datetime_usec
      add :hdop, :float
      add :recorded_speed_mps, :float
      add :derived_speed_mps, :float
      add :cumulative_distance_m, :float, null: false, default: 0.0
      add :grade_percent, :float
      add :valid, :boolean, null: false, default: true
      add :extras, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:track_points, [:track_id, :position])
    create index(:track_points, [:track_segment_id, :position])
    create index(:track_points, [:track_id, :recorded_at])

    create table(:track_waypoints) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :name, :string
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :elevation_m, :float
      add :recorded_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:track_waypoints, [:track_id])

    create table(:analysis_events) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :position, :integer, null: false
      add :start_point_position, :integer
      add :end_point_position, :integer
      add :start_distance_m, :float
      add :end_distance_m, :float
      add :duration_s, :float
      add :metrics, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:analysis_events, [:track_id, :kind])

    create table(:track_splits) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :position, :integer, null: false
      add :start_distance_m, :float, null: false
      add :end_distance_m, :float, null: false
      add :duration_s, :float
      add :distance_m, :float, null: false
      add :avg_speed_mps, :float
      add :elevation_gain_m, :float
      add :metrics, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:track_splits, [:track_id, :kind])

    create table(:track_renderings) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :level, :string, null: false
      add :encoded_polyline, :text, null: false
      add :point_count, :integer, null: false
      add :series, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:track_renderings, [:track_id, :level])

    create table(:route_cells) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :precision, :integer, null: false
      add :cell, :string, null: false
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :point_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_cells, [:track_id, :precision, :cell])
    create index(:route_cells, [:precision, :cell])

    create table(:route_clusters) do
      add :name, :string, null: false
      add :fingerprint, :string, null: false
      add :track_count, :integer, null: false, default: 0
      add :stats, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_clusters, [:fingerprint])

    create table(:route_cluster_memberships) do
      add :route_cluster_id, references(:route_clusters, on_delete: :delete_all), null: false
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :similarity, :float, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_cluster_memberships, [:route_cluster_id, :track_id])
    create unique_index(:route_cluster_memberships, [:track_id])

    create table(:track_enrichments) do
      add :track_id, references(:tracks, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :provider, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :payload, :map, null: false, default: %{}
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:track_enrichments, [:track_id, :kind, :provider])

    create table(:provider_cache) do
      add :provider, :string, null: false
      add :key, :string, null: false
      add :payload, :map, null: false
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_cache, [:provider, :key])

    create table(:app_settings) do
      add :key, :string, null: false
      add :value, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_settings, [:key])
  end
end
