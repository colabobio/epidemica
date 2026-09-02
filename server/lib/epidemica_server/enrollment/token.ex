defmodule EpidemicaServer.Enrollment.Token do
  @moduledoc """
  A participant credential, stored only as a hash.

  Per the M1 decision recorded in the milestone plan (§3.2): opaque random bytes, device-bound,
  revocable, with a long expiry. Deliberately not a JWT — a self-contained token cannot be revoked
  without a denylist, which would reintroduce the database lookup that JWTs exist to avoid, and
  revocation matters more here than saving one query.

  Lifetime and rotation policy are ADR-0005's to settle; this is the minimum that satisfies the
  ingest contract without prejudging it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tokens" do
    field :kind, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :device, EpidemicaServer.Enrollment.Device, foreign_key: :device_row_id
    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:kind, :token_hash, :expires_at, :revoked_at, :device_row_id])
    |> validate_required([:kind, :token_hash, :expires_at, :device_row_id])
    |> validate_inclusion(:kind, ~w(access refresh))
    |> unique_constraint(:token_hash)
  end
end
