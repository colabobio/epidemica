defmodule EpidemicaServer.Repo.Migrations.CreateParticipantStates do
  use Ecto.Migration

  def change do
    # What the server tells a device about its own participant. One row per participant, updated in
    # place: the history of how a state was arrived at belongs to the ticks that produced it, not
    # here, and duplicating it would give two places to disagree.
    create table(:participant_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :participant_id, references(:participants, type: :binary_id, on_delete: :delete_all),
        null: false

      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false

      add :state_uri, :text, null: false

      # Monotonic per participant. Lets a client tell a stale cached document from a current one
      # without comparing timestamps, and lets it discard a response that arrived out of order.
      add :revision, :bigint, null: false, default: 0

      # When the computation ran, not when the row was written. A daily study is a day stale by
      # design and the interface should be able to say so.
      add :as_of, :utc_datetime_usec, null: false

      add :state, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:participant_states, [:participant_id])
  end
end
