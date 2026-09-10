defmodule Mix.Tasks.Epidemica.SeedStudy do
  @shortdoc "Register a study from an authored protocol bundle"

  @moduledoc """
  Registers a study and a join code from a bundle file.

      mix epidemica.seed_study --bundle ../studies/contactlog/bundle.json --code CONTACTLOG-2026

  The bundle's bytes are stored verbatim and its hash derived from them, so the hash always
  describes exactly what will be served. Re-running with the same file is safe: it adds another
  join code to the existing study rather than creating a second copy of it.

  Options:

    --bundle      Path to the bundle JSON. Required.
    --code        Join code participants type in. Defaults to the bundle's own `join_code`.
    --name        Study name for operators. Defaults to the bundle's `title`.
    --arm         Arm to assign to participants using this code.
    --steal-code  Move the code from whichever study currently holds it. For development, where
                  re-seeding a tweaked bundle under the same code is the point and the previous
                  study is scrap.

  A code already held by a *different* study is refused, and nothing is created. Codes are unique
  across every study, so attaching one twice would leave the new study with no way in while devices
  using it enrolled in the old one — which looks like a working seed and fails in a room with people
  waiting.
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
        strict: [
          bundle: :string,
          code: :string,
          name: :string,
          arm: :string,
          steal_code: :boolean
        ]
      )

    path = opts[:bundle] || Mix.raise("--bundle is required")
    source = File.read!(path)
    decoded = Jason.decode!(source)

    name = opts[:name] || decoded["title"] || Path.basename(path)

    code =
      opts[:code] || decoded["join_code"] || Mix.raise("no --code and no join_code in bundle")

    hash = Study.hash_of(source)
    registered = Repo.get_by(Study, protocol_hash: hash)

    # Before anything is created. A study registered and then refused a code is litter: it prints an
    # id, keeps its instruments, and has no way in.
    ensure_code_available(code, registered, opts)

    study =
      case registered do
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

    attach_code(study, code, opts)

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

  defp explain(path, {:arms_share_a_name, repeated}) do
    """
    #{path} declares more than one arm called #{Enum.map_join(repeated, ", ", &inspect/1)}.

    An arm's name is the label analysis splits by, so two arms sharing one merges the conditions
    into a single group -- exactly the comparison the study exists to make -- and the merge leaves
    no trace afterwards.
    """
  end

  defp explain(path, reason), do: "#{path} could not be registered: #{inspect(reason)}"

  defp describe(error) when is_list(error) do
    error
    |> Keyword.take([:instance_location, :absolute_keyword_location])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp describe(other), do: inspect(other)

  # Refused here rather than after the study exists, so a rejected seed changes nothing at all.
  defp ensure_code_available(code, registered, opts) do
    owner = Studies.join_code_owner(code)

    cond do
      owner == nil -> :ok
      registered != nil and owner.study_id == registered.id -> :ok
      Keyword.get(opts, :steal_code, false) -> :ok
      true -> Mix.raise(code_taken(code, owner))
    end
  end

  defp attach_code(study, code, opts) do
    previous = Studies.join_code_owner(code)

    result =
      if Keyword.get(opts, :steal_code, false),
        do: Studies.move_join_code(study, code, opts[:arm]),
        else: Studies.add_join_code(study, code, opts[:arm])

    case result do
      {:ok, _} ->
        if previous != nil and previous.study_id != study.id do
          Mix.shell().info("Join code: #{code} (moved from study #{previous.study_id})")
          Mix.shell().info("Study #{previous.study_id} is no longer joinable.")
        else
          Mix.shell().info("Join code: #{code}")
        end

      {:error, {:code_taken, other}} ->
        Mix.raise(code_taken(code, %{study_id: other}))

      {:error, :study_randomises_arms} ->
        Mix.raise("""
        #{code} was given --arm, but this study declares `rules.arms` and randomises instead.

        Both decide a participant's arm and only one can win. Stamping the arm on a code is
        stratification by who you handed which code to; `rules.arms` is a draw at enrolment. Pick
        the one the protocol means and drop the other.
        """)

      {:error, reason} ->
        Mix.raise("could not attach join code #{code}: #{inspect(reason)}")
    end
  end

  defp code_taken(code, owner) do
    """
    The join code #{code} already belongs to study #{owner.study_id}.

    Codes are unique across every study, so this one cannot also point at the study you are
    registering. Nothing has been created.

    This is what re-seeding a bundle with a new start time looks like: the bundle's bytes changed,
    so it is a different study, but the code still sends devices to the old one.

      --code OTHER-CODE     register this study under a code of its own
      --steal-code          move #{code} to this study, making the old one unjoinable

    `--steal-code` is for development, where the previous study is scrap. In the field it silently
    redirects everyone already holding the code.
    """
  end

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
