defmodule Mix.Tasks.Epidemica.Tick do
  @shortdoc "Runs the twin and settles the score for one study-day"

  @moduledoc """
  Advance a study by one day, or catch it up to the present.

      mix epidemica.tick --study <uuid> --day 3
      mix epidemica.tick --study <uuid> --catch-up

  A day already run is reported and skipped rather than recomputed: participants have been told
  what happened, and a task run twice by accident must not change it.
  """

  use Mix.Task

  alias EpidemicaServer.{Epigame, Studies, Twin}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [study: :string, day: :integer, catch_up: :boolean])

    study_id = opts[:study] || Mix.raise("--study <uuid> is required")

    case Studies.get_study(study_id) do
      nil -> Mix.raise("no study #{study_id}")
      study -> run_days(study, days_to_run(study, opts))
    end
  end

  defp days_to_run(study, opts) do
    cond do
      opts[:day] -> [opts[:day]]
      opts[:catch_up] -> catch_up_days(study)
      true -> Mix.raise("give either --day <n> or --catch-up")
    end
  end

  defp catch_up_days(study) do
    case Studies.day_at(study) do
      nil -> Mix.raise("the study is not running right now: it has not started, or it has ended")
      today -> Enum.to_list(1..today)
    end
  end

  defp run_days(study, days) do
    Enum.each(days, fn day ->
      Mix.shell().info("day #{day}:")
      Mix.shell().info("  twin      #{describe(Twin.run_tick(study.id, day))}")
      Mix.shell().info("  settle    #{describe(Epigame.settle_day(study.id, day))}")
    end)
  end

  defp describe({:ok, _}), do: "ok"
  defp describe({:error, :already_run}), do: "already run, left alone"
  defp describe({:error, :already_settled}), do: "already settled, left alone"
  defp describe({:error, :not_a_twin_study}), do: "skipped, this study has no twin"
  defp describe({:error, :not_a_scored_study}), do: "skipped, this study has no rules"
  defp describe({:error, :no_tick}), do: "skipped, the day has not been simulated"
  defp describe({:error, reason}), do: "failed: #{inspect(reason)}"
end
