defmodule EpidemicaServer.Ops do
  @moduledoc """
  Operator entry points, callable from a release with `bin/epidemica_server eval`.

  A release has no Mix, so the `mix epidemica.tick` tasks are unavailable exactly where they are
  most needed. These exist so that somebody fixing a live study calls a named function rather than
  composing multi-line Elixir into a shell string under pressure. Deliberately small: the point is
  that they are findable and correct, not that they are comprehensive.
  """

  alias EpidemicaServer.{Studies, Twin}

  @doc """
  Run every missing tick for a study, up to now, in order.

      bin/epidemica_server eval 'EpidemicaServer.Ops.catch_up("STUDY_ID")'

  Synchronous and in-process, unlike the scheduler, because an operator running this is watching the
  output. Safe to repeat: a day already run reports `already_run` rather than running again.
  """
  def catch_up(study_id) do
    with {:ok, study} <- fetch(study_id),
         {:ok, days} <- Studies.days_to_catch_up(study) do
      {:ok, for(day <- days, do: {day, Twin.run_tick(study.id, day)})}
    end
  end

  @doc """
  Print a study's tick status, changing nothing.

      bin/epidemica_server eval 'EpidemicaServer.Ops.status("STUDY_ID")'
  """
  def status(study_id) do
    with {:ok, study} <- fetch(study_id) do
      ticked = study.id |> Twin.ticks() |> MapSet.new(& &1.day)

      IO.puts("study:   #{study.name} (#{study.id})")
      IO.puts("status:  #{study.status}")

      case Studies.days_to_catch_up(study) do
        {:error, reason} ->
          IO.puts("days:    #{reason}")

        {:ok, days} ->
          due = Enum.reject(days, &MapSet.member?(ticked, &1))
          IO.puts("ticked:  #{MapSet.size(ticked)} of #{length(days)} day(s) so far")
          IO.puts("behind:  #{if due == [], do: "nothing", else: Enum.join(due, ", ")}")
      end

      # Not the same question as `behind`. A day can be over and not yet due, because its buffer has
      # not passed; an operator chasing a missing tick needs to be able to tell those apart.
      pending = for {id, day} <- Twin.Scheduler.due_ticks(), id == study.id, do: day
      IO.puts("due now: #{if pending == [], do: "nothing", else: Enum.join(pending, ", ")}")

      :ok
    end
  end

  defp fetch(study_id) do
    case Studies.get_study(study_id) do
      nil -> {:error, :not_found}
      study -> {:ok, study}
    end
  end
end
