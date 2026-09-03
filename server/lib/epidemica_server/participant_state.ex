defmodule EpidemicaServer.ParticipantState do
  @moduledoc """
  The downward channel: what the server tells a device about its own participant.

  The mirror image of the observation envelope. Observations flow up carrying a `schema_uri` and an
  opaque payload; state flows down carrying a `state_uri` and an opaque state document. Nothing here
  knows what a particular study's state means, which is what keeps one study's vocabulary out of the
  platform.
  """

  import Ecto.Query

  alias EpidemicaServer.Contracts
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.ParticipantState.Record
  alias EpidemicaServer.Repo

  @state_version "1.0"

  @doc """
  Replace a participant's state, bumping the revision.

  The revision is incremented by the database in the same statement that writes the state, so two
  concurrent writers cannot both read revision 4 and both write revision 5.

  The state is validated against the contract its `state_uri` names before it is stored, so a
  malformed document is caught once here rather than by every client at once. A client cannot catch
  it for us: `state` is opaque to core, and a study renderer reading a missing field leniently shows
  a default, which on screen is indistinguishable from a computed answer.
  """
  def put(study_id, subject, state_uri, state, as_of \\ DateTime.utc_now()) do
    # Who it is for is checked before what it says: "no such participant" is the more fundamental
    # error, and reporting a schema complaint for someone who is not enrolled would be misleading.
    case participant_id(study_id, subject) do
      nil ->
        {:error, :no_such_participant}

      participant_id ->
        with :ok <- validate(state_uri, state) do
          write(participant_id, study_id, subject, state_uri, state, as_of)
        end
    end
  end

  # An unknown `state_uri` passes: a study may define a state shape this build has never seen, and
  # refusing it would make the channel useless to exactly the studies it exists for.
  defp validate(state_uri, state) do
    case Contracts.validate_state(state_uri, state) do
      :ok -> :ok
      {:error, error} -> {:error, {:invalid_state, error}}
    end
  end

  defp write(participant_id, study_id, subject, state_uri, state, as_of) do
    now = DateTime.utc_now()

    {1, [record]} =
      Repo.insert_all(
        Record,
        [
          %{
            id: Ecto.UUID.generate(),
            participant_id: participant_id,
            study_id: study_id,
            state_uri: state_uri,
            revision: 1,
            as_of: as_of,
            state: state,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict:
          from(r in Record,
            update: [
              set: [
                state_uri: fragment("EXCLUDED.state_uri"),
                as_of: fragment("EXCLUDED.as_of"),
                state: fragment("EXCLUDED.state"),
                updated_at: fragment("EXCLUDED.updated_at")
              ],
              inc: [revision: 1]
            ]
          ),
        conflict_target: [:participant_id],
        returning: true
      )

    {:ok, document(record, subject)}
  end

  @doc "The current state document for a participant, or `:not_found` before anything has been computed."
  def fetch(study_id, subject) do
    query =
      from r in Record,
        join: p in Participant,
        on: p.id == r.participant_id,
        where: p.study_id == ^study_id and p.subject == ^subject,
        select: r

    case Repo.one(query) do
      nil -> {:error, :not_found}
      record -> {:ok, document(record, subject)}
    end
  end

  defp participant_id(study_id, subject) do
    Repo.one(
      from p in Participant,
        where: p.study_id == ^study_id and p.subject == ^subject,
        select: p.id
    )
  end

  defp document(record, subject) do
    %{
      state_version: @state_version,
      study_id: record.study_id,
      subject: subject,
      state_uri: record.state_uri,
      revision: record.revision,
      as_of: record.as_of,
      state: record.state
    }
  end
end
