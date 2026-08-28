defmodule TrackAnalyzer.Tracks.RouteCluster do
  use Ecto.Schema
  import Ecto.Changeset

  schema "route_clusters" do
    field :name, :string
    field :fingerprint, :string
    field :track_count, :integer, default: 0
    field :activity_type, :string
    field :matcher_version, :integer, default: 1
    field :stats, :map, default: %{}

    belongs_to :representative_track, TrackAnalyzer.Tracks.Track
    has_many :memberships, TrackAnalyzer.Tracks.RouteClusterMembership
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cluster, attrs) do
    cluster
    |> cast(attrs, [
      :name,
      :fingerprint,
      :track_count,
      :activity_type,
      :matcher_version,
      :stats,
      :representative_track_id
    ])
    |> validate_required([:name, :fingerprint, :track_count, :matcher_version])
    |> validate_number(:track_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:fingerprint)
  end
end
