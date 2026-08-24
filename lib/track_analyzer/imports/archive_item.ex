defmodule TrackAnalyzer.Imports.ArchiveItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "archive_items" do
    field :position, :integer
    field :path, :string
    field :type, :string
    field :subtype, :string
    field :sha256, :string
    field :status, :string, default: "queued"
    field :manifest, :map, default: %{}
    field :error, :string

    belongs_to :source_archive, TrackAnalyzer.Imports.SourceArchive
    belongs_to :track, TrackAnalyzer.Tracks.Track
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :source_archive_id,
      :track_id,
      :position,
      :path,
      :type,
      :subtype,
      :sha256,
      :status,
      :manifest,
      :error
    ])
    |> validate_required([:source_archive_id, :position, :path, :type])
    |> validate_inclusion(
      :status,
      ~w(queued extracted processing complete duplicate insufficient_data failed ignored)
    )
    |> unique_constraint([:source_archive_id, :path])
  end
end
