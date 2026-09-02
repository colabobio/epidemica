defmodule EpidemicaServer.Epigame.LedgerEntry do
  @moduledoc "One settled participant-day. Written once and never revised."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_ledger" do
    field :study_id, :binary_id
    field :subject, :string
    field :day, :integer
    field :closing, :integer
    field :settlement, :map
    field :settled_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(study_id subject day closing settlement settled_at)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_adds_up()
    |> unique_constraint([:study_id, :subject, :day])
  end

  # The arithmetic is the whole point of publishing it; a settlement that does not reconcile would
  # be worse than showing nothing, because it invites a participant to trust it.
  defp validate_adds_up(changeset) do
    settlement = get_field(changeset, :settlement) || %{}
    lines = Map.get(settlement, "lines") || Map.get(settlement, :lines) || []
    opening = Map.get(settlement, "opening") || Map.get(settlement, :opening)
    closing = get_field(changeset, :closing)

    movement =
      Enum.sum(Enum.map(lines, fn line -> Map.get(line, "points") || Map.get(line, :points) end))

    if is_integer(opening) and is_integer(closing) and opening + movement != closing do
      add_error(changeset, :settlement, "lines do not account for the movement in the balance")
    else
      changeset
    end
  end
end
