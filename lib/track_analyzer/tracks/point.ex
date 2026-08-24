defmodule TrackAnalyzer.Tracks.Point do
  use Ecto.Schema
  import Ecto.Changeset

  schema "track_points" do
    field :position, :integer
    field :latitude, :float
    field :longitude, :float
    field :elevation_m, :float
    field :recorded_at, :utc_datetime_usec
    field :hdop, :float
    field :recorded_speed_mps, :float
    field :derived_speed_mps, :float
    field :cumulative_distance_m, :float, default: 0.0
    field :grade_percent, :float
    field :valid, :boolean, default: true
    field :extras, :map, default: %{}

    belongs_to :track, TrackAnalyzer.Tracks.Track
    belongs_to :segment, TrackAnalyzer.Tracks.Segment, foreign_key: :track_segment_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(point, attrs) do
    point
    |> cast(attrs, [
      :track_id,
      :track_segment_id,
      :position,
      :latitude,
      :longitude,
      :elevation_m,
      :recorded_at,
      :hdop,
      :recorded_speed_mps,
      :derived_speed_mps,
      :cumulative_distance_m,
      :grade_percent,
      :valid,
      :extras
    ])
    |> validate_required([:track_id, :track_segment_id, :position, :latitude, :longitude])
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
  end
end
