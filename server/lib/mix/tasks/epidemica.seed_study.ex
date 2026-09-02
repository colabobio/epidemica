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
    code = opts[:code] || decoded["join_code"] || Mix.raise("no --code and no join_code in bundle")
    hash = Study.hash_of(source)

    study =
      case Repo.get_by(Study, protocol_hash: hash) do
        nil ->
          {:ok, study} = Studies.create_study_from_bundle(name, source)
          Mix.shell().info("Created study #{study.id}")
          study

        existing ->
          Mix.shell().info("Study #{existing.id} already registered with this bundle")
          existing
      end

    case Studies.add_join_code(study, code, opts[:arm]) do
      {:ok, _} -> Mix.shell().info("Join code: #{code}")
      {:error, _} -> Mix.shell().info("Join code #{code} already exists")
    end

    Mix.shell().info("""

    Study:         #{study.name}
    Study id:      #{study.id}
    Protocol hash: #{hash}
    Bundle URL:    #{EpidemicaServerWeb.Endpoint.url()}/v1/studies/#{study.id}/protocol

    Point the app at this server and join with #{code}:

      flutter run --dart-define=EPIDEMICA_SERVER=#{EpidemicaServerWeb.Endpoint.url()}/v1/
    """)
  end
end
