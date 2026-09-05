defmodule EpidemicaServer.Ops do
  @moduledoc """
  Operator entry points callable from a release via `bin/epidemica_server eval`.

  These exist so that an operator fixing a live study is calling a named function with a signature,
  not inlining multi-line Elixir into a shell string under pressure. Everything here is deliberately
  small: the point is that it is *findable and correct*, not that it is comprehensive.
  """

  alias EpidemicaServer.Twin

  @doc """
  Run every missing tick for a study up to now. `study_id` is the UUID as a string.

      bin/epidemica_server eval 'EpidemicaServer.Ops.catch_up("STUDY_ID")'
  """
  def catch_up(study_id) do
    case EpidemicaServer.Studies.get_study(study_id) do
      nil ->
        {:error, :not_found}

      study ->
        case EpidemicaServer.Studies.days_to_catch_up(study) do
          {:error, reason} ->
            {:error, reason}

          {:ok, days} ->
            results = for day <- days, do: {day, Twin.run_tick(study_id, day)}
            {:ok, results}
        end
    end
  end

  @doc """
  Print a study's tick status without changing anything. `study_id` is the UUID as a string.

      bin/epidemica_server eval 'EpidemicaServer.Ops.status("STUDY_ID")'
  """
  def status(study_id) do
    case EpidemicaServer.Studies.get_study(study_id) do
      nil ->
        {:error, :not_found}

      study ->
        ticks = Twin.ticks(study_id)
        days = EpidemicaServer.Studies.days_to_catch_up(study)

        IO.puts("study: #{study.name} (#{study.id})")

        case days do
          {:error, reason} ->
            IO.puts("  catch-up: #{reason}")

          {:ok, days} ->
            ticked = MapSet.new(Enum.map(ticks, & &1.day))
            due = Enum.reject(days, &MapSet.member?(ticked, &1))
            IO.puts("  ticks run: #{length(ticks)} of #{length(days)} day(s)")
            IO.puts("  due: #{if due == [], do: "none", else: Enum.join(due, ", ")}")
        end

        :ok
    end
  end
end
