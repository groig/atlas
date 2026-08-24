defmodule TrackAnalyzer.Imports.SourceArchive do
  use Ecto.Schema
  import Ecto.Changeset

  schema "source_archives" do
    field :sha256, :string
    field :original_filename, :string
    field :storage_path, :string
    field :byte_size, :integer
    field :manifest_version, :integer
    field :manifest, :map, default: %{}
    field :status, :string, default: "queued"
    field :progress, :integer, default: 0
    field :stage, :string, default: "Queued"
    field :item_count, :integer, default: 0
    field :new_count, :integer, default: 0
    field :duplicate_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :complete_count, :integer, default: 0
    field :warning, :string
    field :error, :string

    belongs_to :import_batch, TrackAnalyzer.Imports.ImportBatch
    has_many :items, TrackAnalyzer.Imports.ArchiveItem
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(archive, attrs) do
    archive
    |> cast(attrs, [
      :import_batch_id,
      :sha256,
      :original_filename,
      :storage_path,
      :byte_size,
      :manifest_version,
      :manifest,
      :status,
      :progress,
      :stage,
      :item_count,
      :new_count,
      :duplicate_count,
      :failed_count,
      :complete_count,
      :warning,
      :error
    ])
    |> validate_required([:sha256, :original_filename, :storage_path, :byte_size])
    |> validate_inclusion(
      :status,
      ~w(queued inspecting processing complete partial duplicate failed)
    )
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
