defmodule EpidemicaServer.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", "DROP EXTENSION IF EXISTS pgcrypto"

    create table(:studies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :protocol_hash, :string, null: false
      add :protocol, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    create table(:join_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :arm, :string
      timestamps(type: :utc_datetime_usec)
    end

    # Codes are matched case-insensitively so a participant typing them from a poster or a text
    # message is not defeated by capitalisation.
    create unique_index(:join_codes, ["lower(code)"], name: :join_codes_lower_code_index)

    create table(:participants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :subject, :string, null: false
      add :arm, :string
      add :enrolled_at, :utc_datetime_usec, null: false
      add :withdrawn_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:participants, [:study_id, :subject])

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, :binary_id, null: false
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false

      add :participant_id, references(:participants, type: :binary_id, on_delete: :delete_all),
        null: false

      add :platform, :string, null: false
      add :app_version, :string
      add :locale, :string
      timestamps(type: :utc_datetime_usec)
    end

    # A device install has one device_id but may join more than one study, so identity is the pair.
    create unique_index(:devices, [:device_id, :study_id])

    create table(:tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_row_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # Only the hash is stored: a leaked database should not yield usable participant credentials.
    create unique_index(:tokens, [:token_hash])
    create index(:tokens, [:device_row_id, :kind])

    create table(:observations) do
      add :study_id, :binary_id, null: false
      add :subject, :string, null: false
      add :device_id, :binary_id, null: false
      add :seq, :bigint, null: false

      add :module, :string
      add :schema_uri, :text
      add :envelope_version, :string
      add :protocol_hash, :string
      add :observed_at, :utc_datetime_usec
      add :clock_offset_ms, :integer
      add :received_at, :utc_datetime_usec, null: false

      # The envelope is stored exactly as received, and the columns above are extracted from it for
      # querying. Keeping the original makes the store genuinely append-only: a parsing bug can be
      # corrected later by reprojecting rather than by asking the field for data that is gone.
      add :envelope, :map, null: false
      add :payload, :map

      add :validated, :boolean, null: false, default: false
      add :validation_reason, :string
      add :validation_detail, :text
    end

    # The idempotency key. A retry after an ambiguous failure lands here and is reported as a
    # duplicate rather than stored twice.
    create unique_index(:observations, [:device_id, :seq])
    create index(:observations, [:study_id, :observed_at])
    create index(:observations, [:study_id, :module])
    create index(:observations, [:validated], where: "validated = false")

    create table(:contacts) do
      add :observation_id, references(:observations, on_delete: :delete_all), null: false
      add :study_id, :binary_id, null: false
      add :subject, :string, null: false
      add :peer, :string, null: false
      add :pair_key, :string
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec, null: false
      add :duration_s, :float, null: false
      add :band_seconds, :map, null: false
      add :observed_seconds, :float, null: false
      add :sample_count, :integer
      add :gap_count, :integer
    end

    # Projections are derived and rebuildable; nothing writes here except the projector.
    create unique_index(:contacts, [:observation_id])
    create index(:contacts, [:study_id, :started_at])
    create index(:contacts, [:study_id, :subject])
  end
end
