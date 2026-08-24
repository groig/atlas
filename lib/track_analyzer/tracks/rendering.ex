defmodule TrackAnalyzer.Tracks.Rendering do
  use Ecto.Schema

  schema "track_renderings" do
    field :level, :string
    field :encoded_polyline, :string
    field :point_count, :integer
    field :series, :map, default: %{}
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end
end
