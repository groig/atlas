defmodule TrackAnalyzer.Tracks.Segment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "track_segments" do
    field :track_position, :integer
    field :position, :integer
    field :name, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :point_count, :integer, default: 0
    field :distance_m, :float, default: 0.0
    field :stats, :map, default: %{}

    belongs_to :track, TrackAnalyzer.Tracks.Track
    has_many :points, TrackAnalyzer.Tracks.Point, foreign_key: :track_segment_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [
      :track_id,
      :track_position,
      :position,
      :name,
      :started_at,
      :ended_at,
      :point_count,
      :distance_m,
      :stats
    ])
    |> validate_required([:track_id, :track_position, :position])
    |> unique_constraint([:track_id, :track_position, :position])
  end
end
