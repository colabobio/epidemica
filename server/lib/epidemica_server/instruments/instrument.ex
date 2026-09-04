defmodule EpidemicaServer.Instruments.Instrument do
  @moduledoc "One version of one instrument, as registered."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "instruments" do
    field :study_id, :binary_id
    field :instrument_id, :string
    field :version, :string
    field :source, :string
    field :sha256, :string
    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(study_id instrument_id version source sha256)a

  def changeset(instrument, attrs) do
    instrument
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:study_id, :instrument_id, :version],
      name: :instruments_study_id_instrument_id_version_index
    )
  end
end
