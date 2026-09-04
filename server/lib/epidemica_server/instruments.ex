defmodule EpidemicaServer.Instruments do
  @moduledoc """
  Instrument definitions: the questions a study asks, stored and served byte for byte.

  Kept out of the protocol bundle deliberately. A bundle change re-registers the study and creates
  a new one, so carrying the questions inside it would mean a reworded prompt forced every
  participant to re-enrol. Instruments version on their own and a response records which version
  answered it.

  The server does not read them. It stores the bytes, derives their digest, and hands them back —
  the device checks the digest against what the bundle pinned, and the contract that says what a
  well-formed definition looks like is enforced where it is authored, not here.
  """

  import Ecto.Query

  alias EpidemicaServer.Instruments.Instrument
  alias EpidemicaServer.Repo

  @doc """
  Register a definition from its exact bytes.

  Re-registering identical bytes is a no-op, so seeding a study twice is safe. Re-registering
  *different* bytes under the same version is refused: responses already collected name that
  version, and quietly changing what it means would silently merge two measurements.
  """
  def register(study_id, source) when is_binary(source) do
    with {:ok, decoded} <- Jason.decode(source),
         {:ok, id, version} <- identify(decoded) do
      digest = digest_of(source)

      case Repo.get_by(Instrument, study_id: study_id, instrument_id: id, version: version) do
        nil ->
          %Instrument{}
          |> Instrument.changeset(%{
            study_id: study_id,
            instrument_id: id,
            version: version,
            source: source,
            sha256: digest
          })
          |> Repo.insert()

        %Instrument{sha256: ^digest} = existing ->
          {:ok, existing}

        %Instrument{} ->
          {:error, {:version_already_registered, id, version}}
      end
    end
  end

  @doc "The bytes to serve for one instrument, byte-identical to what was registered."
  def fetch_source(study_id, instrument_id, version) do
    query =
      from i in Instrument,
        where:
          i.study_id == type(^study_id, :binary_id) and i.instrument_id == ^instrument_id and
            i.version == ^version,
        select: i.source

    case Repo.one(query) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  @doc "Every instrument registered for a study, as `{instrument_id, version, sha256}`."
  def list(study_id) do
    Repo.all(
      from i in Instrument,
        where: i.study_id == type(^study_id, :binary_id),
        order_by: [i.instrument_id, i.version],
        select: {i.instrument_id, i.version, i.sha256}
    )
  end

  @doc "The digest form the device compares against, over the exact bytes served."
  def digest_of(source) when is_binary(source),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)

  defp identify(%{"instrument_id" => id, "version" => version})
       when is_binary(id) and is_binary(version),
       do: {:ok, id, version}

  defp identify(_), do: {:error, :not_an_instrument}
end
