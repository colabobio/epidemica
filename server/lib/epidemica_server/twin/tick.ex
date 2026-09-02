defmodule EpidemicaServer.Twin.Tick do
  @moduledoc """
  One study-day of the twin, recorded in full.

  Inputs, seed and outputs are stored together because a result nobody can reproduce is not a
  result. Re-running a stored tick and comparing is the only check that the study's history means
  what it claims.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "twin_ticks" do
    field :study_id, :binary_id
    field :day, :integer
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :received_before, :utc_datetime_usec
    field :seed, :integer
    field :engine, :string
    field :engine_version, :string
    field :inputs, :map
    field :outputs, :map
    field :ran_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(study_id day period_start period_end received_before seed engine engine_version
             inputs outputs ran_at)a

  def changeset(tick, attrs) do
    tick
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:day, greater_than_or_equal_to: 0)
    |> unique_constraint([:study_id, :day], name: :twin_ticks_study_id_day_index)
  end
end
