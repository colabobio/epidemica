defmodule Mix.Tasks.Epidemica.ExportNetwork do
  @shortdoc "Write a study's day-by-day contact network as JSON"

  @moduledoc """
  Export every tick of a study as one network document.

      mix epidemica.export_network --study <uuid> --out network.json

  What comes out is the network the *model* saw, not a fresh query of the observation store: the
  edges are the ones the tick was actually run against, read back from `twin_ticks.inputs`, and the
  states are what it produced. A visualisation built from anything else would show a study that
  never happened.

  **Measured contacts only.** The virtual population's mixing is drawn inside the engine from the
  tick's seed and is not stored, so it is absent here. `starsim_epidemica.netviz` reconstructs it
  from the seed this file carries — and without that step the epidemic appears to spread with no
  visible cause, because at ordinary settings virtual contacts outnumber measured ones.
  """

  use Mix.Task

  alias EpidemicaServer.{Studies, Twin}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [study: :string, out: :string])

    study_id = opts[:study] || Mix.raise("--study <uuid> is required")
    out = opts[:out] || Mix.raise("--out <file> is required")

    study =
      case Studies.get_study(study_id) do
        nil -> Mix.raise("no study #{study_id}")
        study -> study
      end

    ticks = Twin.ticks(study_id)
    if ticks == [], do: Mix.raise("study #{study_id} has no ticks to export")

    document = %{
      "study" => describe(study, ticks),
      "agents" => roster(ticks),
      "days" => Enum.map(ticks, &day/1)
    }

    File.write!(out, Jason.encode!(document, pretty: true))

    Mix.shell().info("""
    Wrote #{out}
      #{length(ticks)} days, #{length(document["agents"])} agents, \
    #{Enum.sum(Enum.map(document["days"], &length(&1["edges"])))} measured edges

    Add the virtual population's mixing, which the engine draws rather than stores:

      cd ../models && uv run python -m starsim_epidemica.netviz #{Path.expand(out)}
    """)
  end

  defp describe(study, ticks) do
    %{
      "id" => study.id,
      "name" => study.name,
      "days_total" => Studies.scheduled_days(study),
      "tick_interval_seconds" => Studies.tick_interval(study),
      "days_run" => length(ticks),
      "engine" => List.first(ticks).engine,
      "engine_version" => List.first(ticks).engine_version
    }
  end

  # Taken from the last tick, whose roster is the most complete: participants who joined mid-study
  # are absent from earlier ones, and a node that appears halfway through would look like a defect.
  defp roster(ticks) do
    ticks
    |> List.last()
    |> Map.fetch!(:inputs)
    |> Map.get("agents", [])
    |> Enum.map(fn agent ->
      %{
        "index" => agent["index"],
        "virtual" => agent["virtual"] == true,
        "subject" => agent["subject"]
      }
    end)
  end

  defp day(tick) do
    outputs = Map.get(tick.outputs, "agents", [])

    %{
      "day" => tick.day,
      "period_start" => tick.period_start,
      "period_end" => tick.period_end,
      "seed" => tick.seed,
      "population" => Map.get(tick.inputs, "population", 0),
      "pars" => Map.get(tick.inputs, "pars", %{}),
      "newly_infected" => Map.get(tick.outputs, "newly_infected", 0),
      "total_cases" => Map.get(tick.outputs, "total_cases", 0),
      "agents" => Enum.map(outputs, &agent_day/1),
      "edges" => Enum.map(Map.get(tick.inputs, "contacts", []), &edge/1)
    }
  end

  defp agent_day(agent) do
    %{
      "index" => agent["index"],
      "state" => agent["state"],
      "newly_infected" => agent["newly_infected"] == true,
      "infection" => agent["infection"]
    }
  end

  defp edge(contact) do
    %{
      "a" => contact["a"],
      "b" => contact["b"],
      "seconds" => contact["seconds"],
      "band_seconds" => contact["band_seconds"],
      "kind" => "measured"
    }
  end
end
