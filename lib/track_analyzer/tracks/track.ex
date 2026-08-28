defmodule TrackAnalyzer.Tracks.Track do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracks" do
    field :sha256, :string
    field :original_path, :string
    field :source_filename, :string
    field :source_folder, :string
    field :name, :string
    field :creator, :string
    field :activity_type, :string
    field :status, :string, default: "queued"
    field :stage, :string, default: "Queued"
    field :progress, :integer, default: 0
    field :analysis_version, :integer, default: 1
    field :timezone, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :point_count, :integer, default: 0
    field :segment_count, :integer, default: 0
    field :distance_m, :float
    field :elapsed_s, :float
    field :moving_s, :float
    field :stopped_s, :float
    field :avg_speed_mps, :float
    field :max_speed_mps, :float
    field :best_100m_speed_mps, :float
    field :best_500m_speed_mps, :float
    field :max_speed_confidence, :string
    field :max_speed_point_position, :integer
    field :elevation_gain_m, :float
    field :elevation_loss_m, :float
    field :min_elevation_m, :float
    field :max_elevation_m, :float
    field :quality_score, :float
    field :manifest_distance_m, :float
    field :manifest_time_ms, :integer
    field :bounds, :map, default: %{}
    field :stats, :map, default: %{}
    field :quality, :map, default: %{}
    field :error, :string

    has_many :archive_items, TrackAnalyzer.Imports.ArchiveItem
    has_many :segments, TrackAnalyzer.Tracks.Segment
    has_many :points, TrackAnalyzer.Tracks.Point
    has_many :events, TrackAnalyzer.Tracks.AnalysisEvent
    has_many :splits, TrackAnalyzer.Tracks.Split
    has_many :renderings, TrackAnalyzer.Tracks.Rendering
    has_one :route_cluster_membership, TrackAnalyzer.Tracks.RouteClusterMembership
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [
      :sha256,
      :original_path,
      :source_filename,
      :source_folder,
      :name,
      :creator,
      :activity_type,
      :status,
      :stage,
      :progress,
      :analysis_version,
      :timezone,
      :started_at,
      :ended_at,
      :point_count,
      :segment_count,
      :distance_m,
      :elapsed_s,
      :moving_s,
      :stopped_s,
      :avg_speed_mps,
      :max_speed_mps,
      :best_100m_speed_mps,
      :best_500m_speed_mps,
      :max_speed_confidence,
      :max_speed_point_position,
      :elevation_gain_m,
      :elevation_loss_m,
      :min_elevation_m,
      :max_elevation_m,
      :quality_score,
      :manifest_distance_m,
      :manifest_time_ms,
      :bounds,
      :stats,
      :quality,
      :error
    ])
    |> validate_required([:sha256, :original_path, :source_filename, :name])
    |> validate_inclusion(
      :status,
      ~w(queued parsing cleaning analyzing indexing complete insufficient_data failed cancelled)
    )
    |> validate_inclusion(:max_speed_confidence, ~w(high medium low))
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:sha256)
  end
end
