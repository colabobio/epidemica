defmodule EpidemicaServer.ParticipantState.Record do
  @moduledoc "One participant's current state document."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "participant_states" do
    field :participant_id, :binary_id
    field :study_id, :binary_id
    field :state_uri, :string
    field :revision, :integer
    field :as_of, :utc_datetime_usec
    field :state, :map

    timestamps()
  end
end
