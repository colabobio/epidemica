defmodule EpidemicaServer.Studies.Study do
  @moduledoc "A study: its protocol bundle, the hash clients stamp on every observation, and status."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "studies" do
    field :name, :string
    field :protocol_hash, :string
    field :protocol, :map, default: %{}
    field :status, :string, default: "open"

    has_many :join_codes, EpidemicaServer.Studies.JoinCode
    timestamps()
  end

  def changeset(study, attrs) do
    study
    |> cast(attrs, [:name, :protocol_hash, :protocol, :status])
    |> validate_required([:name, :protocol_hash])
    |> validate_inclusion(:status, ~w(open closed))
    |> validate_format(:protocol_hash, ~r/^sha256:[0-9a-f]{64}$/)
  end
end
