defmodule EpidemicaServer.Twin.Agent do
  @moduledoc """
  One agent in a study's simulated population.

  A slot is claimed once and never reassigned. Reusing one would hand a joining participant the
  epidemiological history of whoever held it before, which is the sort of error that produces a
  plausible-looking result and no way to notice.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "twin_agents" do
    field :study_id, :binary_id
    field :slot, :integer
    field :subject, :string
    field :virtual, :boolean, default: false
    field :active, :boolean, default: true
    field :state, :string, default: "susceptible"
    field :infected_on_day, :integer
    field :recovers_on_day, :integer
    field :dies_on_day, :integer
    field :joined_on_day, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @states ~w(susceptible infected recovered dead)

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :study_id,
      :slot,
      :subject,
      :virtual,
      :active,
      :state,
      :infected_on_day,
      :recovers_on_day,
      :dies_on_day,
      :joined_on_day
    ])
    |> validate_required([:study_id, :slot, :state])
    |> validate_inclusion(:state, @states)
    |> validate_number(:slot, greater_than_or_equal_to: 0)
    |> check_identity()
    |> unique_constraint([:study_id, :slot])
    |> unique_constraint([:study_id, :subject])
  end

  # A real agent without a subject cannot be told its state; a virtual one with a subject would be
  # a simulated person wearing a participant's identity.
  defp check_identity(changeset) do
    virtual = get_field(changeset, :virtual)
    subject = get_field(changeset, :subject)

    cond do
      virtual and subject != nil ->
        add_error(changeset, :subject, "must be blank for a virtual agent")

      not virtual and subject == nil ->
        add_error(changeset, :subject, "is required for a real agent")

      true ->
        changeset
    end
  end
end
