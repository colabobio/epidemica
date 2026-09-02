defmodule EpidemicaServer.Enrollment.Participant do
  @moduledoc """
  A participant in one study, identified only by a client-generated pseudonym.

  There is deliberately no name, email or phone number here. Contact details, when a study needs
  them, live in the separate Contact Registry (roadmap §6.1b) so that the observation store stays
  pseudonymous and shareable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "participants" do
    field :subject, :string
    field :arm, :string
    field :enrolled_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec

    belongs_to :study, EpidemicaServer.Studies.Study
    has_many :devices, EpidemicaServer.Enrollment.Device
    timestamps()
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:subject, :arm, :enrolled_at, :withdrawn_at, :study_id])
    |> validate_required([:subject, :enrolled_at, :study_id])
    # Same rule as the envelope contract: rejects anything containing '@', '.' or whitespace, so an
    # email address cannot be enrolled as a pseudonym by accident.
    |> validate_format(:subject, ~r/^[A-Za-z0-9_-]+$/)
    |> validate_length(:subject, min: 8, max: 128)
    |> unique_constraint([:study_id, :subject])
  end
end
