defmodule TrackAnalyzer.Tracks.Split do
  use Ecto.Schema

  schema "track_splits" do
    field :kind, :string
    field :position, :integer
    field :start_distance_m, :float
    field :end_distance_m, :float
    field :duration_s, :float
    field :distance_m, :float
    field :avg_speed_mps, :float
    field :elevation_gain_m, :float
    field :metrics, :map, default: %{}
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end
end
