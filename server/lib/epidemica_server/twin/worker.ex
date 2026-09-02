defmodule EpidemicaServer.Twin.Worker do
  @moduledoc """
  Runs one study-day of the twin.

  Days are run in order and one at a time, because each tick starts from the state its predecessor
  wrote. A day already decided is reported as done rather than retried: the job failing forever on
  a tick that has already happened would be noise, not a signal.
  """

  use Oban.Worker, queue: :twin, max_attempts: 5

  alias EpidemicaServer.Twin

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"study_id" => study_id, "day" => day}}) do
    case Twin.run_tick(study_id, day) do
      {:ok, _tick} -> :ok
      {:error, :already_run} -> :ok
      {:error, :not_a_twin_study} -> {:cancel, :not_a_twin_study}
      {:error, :not_found} -> {:cancel, :no_such_study}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queue a study-day."
  def enqueue(study_id, day) do
    %{study_id: study_id, day: day} |> new() |> Oban.insert()
  end
end
