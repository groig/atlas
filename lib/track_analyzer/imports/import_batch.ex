defmodule TrackAnalyzer.Imports.ImportBatch do
  use Ecto.Schema
  import Ecto.Changeset

  schema "import_batches" do
    field :status, :string, default: "uploading"
    field :archive_count, :integer, default: 0
    field :item_count, :integer, default: 0
    field :complete_count, :integer, default: 0
    field :duplicate_count, :integer, default: 0
    field :failed_count, :integer, default: 0

    has_many :archives, TrackAnalyzer.Imports.SourceArchive
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :status,
      :archive_count,
      :item_count,
      :complete_count,
      :duplicate_count,
      :failed_count
    ])
    |> validate_inclusion(:status, ~w(uploading processing complete partial failed))
    |> validate_number(:archive_count, greater_than_or_equal_to: 0)
    |> validate_number(:item_count, greater_than_or_equal_to: 0)
  end
end
