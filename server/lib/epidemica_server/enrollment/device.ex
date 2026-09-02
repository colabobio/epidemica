defmodule EpidemicaServer.Enrollment.Device do
  @moduledoc "One app installation enrolled in one study."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "devices" do
    field :device_id, Ecto.UUID
    field :platform, :string
    field :app_version, :string
    field :locale, :string

    belongs_to :study, EpidemicaServer.Studies.Study
    belongs_to :participant, EpidemicaServer.Enrollment.Participant
    has_many :tokens, EpidemicaServer.Enrollment.Token, foreign_key: :device_row_id
    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:device_id, :platform, :app_version, :locale, :study_id, :participant_id])
    |> validate_required([:device_id, :platform, :study_id, :participant_id])
    |> validate_inclusion(:platform, ~w(ios android web))
    |> unique_constraint([:device_id, :study_id])
  end
end
