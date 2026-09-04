defmodule EpidemicaServer.Repo.Migrations.CreateInstruments do
  use Ecto.Migration

  def change do
    # Instruments version independently of the bundle, which is the whole reason they are not in
    # it: rewording a question must not re-register the study and force everyone to re-enrol. So a
    # study can hold several versions of the same instrument at once, and a response names the one
    # it was collected under.
    create table(:instruments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :instrument_id, :string, null: false
      add :version, :string, null: false

      # The exact bytes registered, served back unchanged. A document that round-trips through a
      # decoder can come back with a different key order and a different hash, and the device
      # refuses anything whose digest does not match what the bundle pinned.
      add :source, :text, null: false
      add :sha256, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instruments, [:study_id, :instrument_id, :version])
  end
end
