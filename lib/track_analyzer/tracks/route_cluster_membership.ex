defmodule TrackAnalyzer.Tracks.RouteClusterMembership do
  use Ecto.Schema
  import Ecto.Changeset

  schema "route_cluster_memberships" do
    field :similarity, :float
    field :metrics, :map, default: %{}

    belongs_to :route_cluster, TrackAnalyzer.Tracks.RouteCluster
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:route_cluster_id, :track_id, :similarity, :metrics])
    |> validate_required([:route_cluster_id, :track_id, :similarity])
    |> validate_number(:similarity, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> unique_constraint(:track_id)
    |> unique_constraint([:route_cluster_id, :track_id])
  end
end
