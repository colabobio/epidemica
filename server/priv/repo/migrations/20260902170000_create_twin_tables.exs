defmodule EpidemicaServer.Repo.Migrations.CreateTwinTables do
  use Ecto.Migration

  def change do
    # One row per agent in the simulated population, real or virtual. The slot is permanent: an
    # agent's history is only continuous if nothing ever reassigns its place in the population.
    create table(:twin_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :slot, :integer, null: false
      add :subject, :text
      add :virtual, :boolean, null: false, default: false
      add :active, :boolean, null: false, default: true
      add :state, :text, null: false, default: "susceptible"
      add :infected_on_day, :integer
      add :recovers_on_day, :integer
      add :dies_on_day, :integer
      add :joined_on_day, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:twin_agents, [:study_id, :slot])
    create unique_index(:twin_agents, [:study_id, :subject], where: "subject IS NOT NULL")

    # One row per study-day, written once. The inputs and seed are kept alongside the outputs so a
    # tick can be re-run and checked rather than merely trusted.
    create table(:twin_ticks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :study_id, references(:studies, type: :binary_id, on_delete: :delete_all), null: false
      add :day, :integer, null: false
      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :received_before, :utc_datetime_usec, null: false
      add :seed, :bigint, null: false
      add :engine, :text, null: false
      add :engine_version, :text, null: false
      add :inputs, :map, null: false
      add :outputs, :map, null: false
      add :ran_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # What makes a tick immutable. A second attempt at a day the study has already told
    # participants about is rejected by the database, not by whichever caller remembered to check.
    create unique_index(:twin_ticks, [:study_id, :day])
  end
end
