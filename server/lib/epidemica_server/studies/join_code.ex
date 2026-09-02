defmodule EpidemicaServer.Studies.JoinCode do
  @moduledoc """
  A code a participant types to join a study.

  A study may have several, one per randomised arm, which is how allocation can be handled by
  handing different groups different codes when that suits a design better than server-side
  randomisation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "join_codes" do
    field :code, :string
    field :arm, :string

    belongs_to :study, EpidemicaServer.Studies.Study
    timestamps()
  end

  def changeset(join_code, attrs) do
    join_code
    |> cast(attrs, [:code, :arm, :study_id])
    |> validate_required([:code, :study_id])
    |> validate_length(:code, min: 4, max: 64)
    |> unique_constraint(:code, name: :join_codes_lower_code_index)
  end
end
