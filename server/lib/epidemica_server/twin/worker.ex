defmodule EpidemicaServer.Twin.Worker do
  @moduledoc """
  Runs one study-day of the twin.

  Days are run in order and one at a time, because each tick starts from the state its predecessor
  wrote. A day already decided is reported as done rather than retried: the job failing forever on
  a tick that has already happened would be noise, not a signal.
  """

  use Oban.Worker, queue: :twin, max_attempts: 5

  alias EpidemicaServer.Epigame
  alias EpidemicaServer.Twin

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"study_id" => study_id, "day" => day}}) do
    case Twin.run_tick(study_id, day) do
      {:ok, _tick} -> settle(study_id, day)
      {:error, :already_run} -> settle(study_id, day)
      {:error, :not_a_twin_study} -> {:cancel, :not_a_twin_study}
      {:error, :not_found} -> {:cancel, :no_such_study}
      {:error, reason} -> {:error, reason}
    end
  end

  # Scoring is queued rather than run here so that a failure to settle never looks like a failure to
  # simulate, and never re-runs a day the participants have already been told about.
  defp settle(study_id, day) do
    case Epigame.Worker.enqueue(study_id, day) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queue a study-day."
  def enqueue(study_id, day) do
    %{study_id: study_id, day: day} |> new() |> Oban.insert()
  end
end
