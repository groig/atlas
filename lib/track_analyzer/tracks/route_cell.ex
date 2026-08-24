defmodule TrackAnalyzer.Tracks.RouteCell do
  use Ecto.Schema

  schema "route_cells" do
    field :precision, :integer
    field :cell, :string
    field :latitude, :float
    field :longitude, :float
    field :point_count, :integer, default: 0
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end
end
