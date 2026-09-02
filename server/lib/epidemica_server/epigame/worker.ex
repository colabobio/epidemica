defmodule EpidemicaServer.Epigame.Worker do
  @moduledoc """
  Settles a study-day once its tick has run.

  Separate from the tick job because a tick is immutable once written: if scoring fails there is no
  reason to recompute the epidemic, only to try the arithmetic again.
  """

  use Oban.Worker, queue: :twin, max_attempts: 5

  alias EpidemicaServer.Epigame

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"study_id" => study_id, "day" => day}}) do
    case Epigame.settle_day(study_id, day) do
      {:ok, _} -> :ok
      {:error, :already_settled} -> :ok
      {:error, :not_a_scored_study} -> {:cancel, :not_a_scored_study}
      {:error, :not_found} -> {:cancel, :no_such_study}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queue settlement for a study-day."
  def enqueue(study_id, day) do
    %{study_id: study_id, day: day} |> new() |> Oban.insert()
  end
end
