defmodule TrackAnalyzer.Tracks.AnalysisEvent do
  use Ecto.Schema

  schema "analysis_events" do
    field :kind, :string
    field :position, :integer
    field :start_point_position, :integer
    field :end_point_position, :integer
    field :start_distance_m, :float
    field :end_distance_m, :float
    field :duration_s, :float
    field :metrics, :map, default: %{}
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end
end
