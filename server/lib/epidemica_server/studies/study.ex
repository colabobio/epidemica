defmodule EpidemicaServer.Studies.Study do
  @moduledoc """
  A study: its protocol bundle, the hash clients stamp on every observation, and status.

  `protocol_source` is authoritative. `protocol` is the same document decoded, kept only so the
  server can ask questions like "which studies use the proximity module" — it is never what gets
  served, because re-encoding it would change the bytes a client hashes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "studies" do
    field :name, :string
    field :protocol_hash, :string
    field :protocol, :map, default: %{}
    field :protocol_source, :string
    field :status, :string, default: "open"

    has_many :join_codes, EpidemicaServer.Studies.JoinCode
    timestamps()
  end

  def changeset(study, attrs) do
    study
    |> cast(attrs, [:name, :protocol_hash, :protocol, :protocol_source, :status])
    |> validate_required([:name, :protocol_hash])
    |> validate_inclusion(:status, ~w(open closed))
    |> validate_format(:protocol_hash, ~r/^sha256:[0-9a-f]{64}$/)
    |> validate_hash_matches_source()
  end

  # A study whose stored hash does not describe its stored bytes enrols successfully and is then
  # refused by every client, with the mismatch only visible on the device.
  defp validate_hash_matches_source(changeset) do
    source = get_field(changeset, :protocol_source)
    hash = get_field(changeset, :protocol_hash)

    cond do
      is_nil(source) or is_nil(hash) -> changeset
      hash == hash_of(source) -> changeset
      true -> add_error(changeset, :protocol_hash, "does not match protocol_source")
    end
  end

  @doc "The `sha256:` hash of a bundle's exact bytes."
  def hash_of(source) when is_binary(source),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)
end
