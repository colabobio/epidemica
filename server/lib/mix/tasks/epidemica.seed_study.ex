defmodule Mix.Tasks.Epidemica.SeedStudy do
  @shortdoc "Register a study from an authored protocol bundle"

  @moduledoc """
  Registers a study and a join code from a bundle file.

      mix epidemica.seed_study --bundle ../studies/contactlog/bundle.json --code CONTACTLOG-2026

  The bundle's bytes are stored verbatim and its hash derived from them, so the hash always
  describes exactly what will be served. Re-running with the same file is safe: it adds another
  join code to the existing study rather than creating a second copy of it.

  Options:

    --bundle  Path to the bundle JSON. Required.
    --code    Join code participants type in. Defaults to the bundle's own `join_code`.
    --name    Study name for operators. Defaults to the bundle's `title`.
    --arm     Arm to assign to participants using this code.
  """

  use Mix.Task

  alias EpidemicaServer.Instruments
  alias EpidemicaServer.Repo
  alias EpidemicaServer.Studies
  alias EpidemicaServer.Studies.Study

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [bundle: :string, code: :string, name: :string, arm: :string]
      )

    path = opts[:bundle] || Mix.raise("--bundle is required")
    source = File.read!(path)
    decoded = Jason.decode!(source)

    name = opts[:name] || decoded["title"] || Path.basename(path)

    code =
      opts[:code] || decoded["join_code"] || Mix.raise("no --code and no join_code in bundle")

    hash = Study.hash_of(source)

    study =
      case Repo.get_by(Study, protocol_hash: hash) do
        nil ->
          case Studies.create_study_from_bundle(name, source) do
            {:ok, study} ->
              Mix.shell().info("Created study #{study.id}")
              study

            {:error, reason} ->
              Mix.raise(explain(path, reason))
          end

        existing ->
          Mix.shell().info("Study #{existing.id} already registered with this bundle")
          existing
      end

    case Studies.add_join_code(study, code, opts[:arm]) do
      {:ok, _} -> Mix.shell().info("Join code: #{code}")
      {:error, _} -> Mix.shell().info("Join code #{code} already exists")
    end

    register_instruments(study, path, decoded)

    Mix.shell().info("""

    Study:         #{study.name}
    Study id:      #{study.id}
    Protocol hash: #{hash}
    Bundle URL:    #{EpidemicaServerWeb.Endpoint.url()}/v1/studies/#{study.id}/protocol

    Point the app at this server and join with #{code}:

      flutter run --dart-define=EPIDEMICA_SERVER=#{EpidemicaServerWeb.Endpoint.url()}/v1/
    """)
  end

  # Every one of these is a study that would have registered, run, and produced nothing usable. The
  # message has to name the file and the key, because the author is looking at JSON and not at this.
  defp explain(path, {:invalid_bundle, error}) do
    """
    #{path} is not a valid study protocol bundle.

      #{describe(error)}

    The bundle schema is closed at the top level, so an unrecognised key is a mistyped one. See
    contracts/bundle/1.0.0.json.
    """
  end

  defp explain(path, {:coverage_not_reported, _tick}) do
    """
    #{path} runs a twin but switches health reporting off.

    Coverage is only ever claimed by module_status observations. With none, every participant is
    below the coverage threshold on every day, which the twin reads as protected: nobody would
    transmit, nobody would score, and nothing would report an error.

    Either remove the `twin` block or set `health.enabled` to true.
    """
  end

  defp explain(path, {:health_interval_too_long, interval, maximum}) do
    """
    #{path} closes a coverage window every #{interval}s, which is too slow for how often it ticks.

      health.interval_seconds:  #{interval}
      largest that can work:    #{maximum}

    The window in progress has not been reported yet, so at most one health interval of every tick
    period is ever uncovered. Above #{maximum}s no device can reach the coverage threshold, so every
    round would be scored `not_sensing` and the epidemic would not spread — silently.
    """
  end

  defp explain(path, reason), do: "#{path} could not be registered: #{inspect(reason)}"

  defp describe(error) when is_list(error) do
    error
    |> Keyword.take([:instance_location, :absolute_keyword_location])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp describe(other), do: inspect(other)

  # Instrument definitions live beside the bundle rather than inside it, because a reworded
  # question must not change the protocol hash and re-register the study.
  defp register_instruments(study, bundle_path, decoded) do
    dir = Path.join(Path.dirname(bundle_path), "instruments")

    for file <- Path.wildcard(Path.join(dir, "*.json")) do
      case Instruments.register(study.id, File.read!(file)) do
        {:ok, instrument} ->
          Mix.shell().info("Instrument: #{instrument.instrument_id}@#{instrument.version}")

        {:error, {:version_already_registered, id, version}} ->
          Mix.raise("""
          #{id}@#{version} is already registered with different bytes.

          Responses already collected name that version. Changing what it means would merge two
          measurements into one. Give the edited instrument a new version instead.
          """)

        {:error, reason} ->
          Mix.raise("#{file} is not an instrument definition: #{inspect(reason)}")
      end
    end

    verify_declared(study, decoded)
  end

  # A digest the bundle got wrong would otherwise surface as a phone quietly refusing to show a
  # survey, which is a long way from the file that is actually wrong.
  defp verify_declared(study, decoded) do
    registered = Map.new(Instruments.list(study.id), fn {id, v, digest} -> {{id, v}, digest} end)

    declared =
      decoded
      |> get_in(["modules", "survey", "instruments"])
      |> List.wrap()

    for entry <- declared, is_map(entry) do
      key = {entry["instrument_id"], entry["version"]}

      case Map.fetch(registered, key) do
        :error ->
          Mix.raise(
            "the bundle schedules #{elem(key, 0)}@#{elem(key, 1)}, " <>
              "but no such definition was found beside it"
          )

        {:ok, digest} ->
          if digest != entry["sha256"] do
            Mix.raise("""
            #{elem(key, 0)}@#{elem(key, 1)} does not match the digest the bundle pinned.

              bundle:     #{entry["sha256"]}
              definition: #{digest}

            The device refuses a definition whose digest differs, so this would show up in the
            field as a survey that never appears.
            """)
          end
      end
    end
  end
end
