defmodule EpidemicaServer.Ingest.Observation do
  @moduledoc """
  One observation exactly as received, plus the fields extracted from it for querying.

  Append-only: nothing updates a row here except the re-validation pass that runs after a deploy
  adds a schema the server previously did not know.
  """

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "observations" do
    field :study_id, Ecto.UUID
    field :subject, :string
    field :device_id, Ecto.UUID
    field :seq, :integer

    field :module, :string
    field :schema_uri, :string
    field :envelope_version, :string
    field :protocol_hash, :string
    field :observed_at, :utc_datetime_usec
    field :clock_offset_ms, :integer
    field :received_at, :utc_datetime_usec

    field :envelope, :map
    field :payload, :map

    field :validated, :boolean, default: false
    field :validation_reason, :string
    field :validation_detail, :string
  end
end
