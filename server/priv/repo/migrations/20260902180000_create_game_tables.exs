defmodule EpidemicaServer.Repo.Migrations.CreateGameTables do
  use Ecto.Migration

  def change do
    # One settled day per participant, written once. The settlement is kept in full rather than
    # just the balance, because a score a participant cannot check is a score they can only accept.
    create table(:game_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :subject, :text, null: false
      add :day, :integer, null: false
      add :closing, :integer, null: false
      add :settlement, :map, null: false
      add :settled_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:game_ledger, [:study_id, :subject, :day])

    # A pair-day is paid once, ever. This is what enforces the cooldown and what lets a contact
    # whose other side arrived late be credited without any risk of paying for it twice.
    create table(:game_contact_awards, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :subject, :text, null: false
      add :peer, :text, null: false
      add :day, :integer, null: false
      add :awarded_on_day, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:game_contact_awards, [:study_id, :subject, :peer, :day])
    create index(:game_contact_awards, [:study_id, :awarded_on_day])

    # Protection is an action with a time, not a flag. A participant claiming afterwards that they
    # were protected all along has to be answerable from the record.
    create table(:game_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :subject, :text, null: false
      add :type, :text, null: false
      add :effective_from, :utc_datetime_usec, null: false
      add :effective_until, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:game_actions, [:study_id, :subject, :effective_from])
  end
end
