defmodule EpidemicaServer.Studies do
  @moduledoc "Studies, their protocol bundles, and the codes participants join with."

  import Ecto.Query

  alias EpidemicaServer.Repo
  alias EpidemicaServer.Studies.{JoinCode, Study}

  def create_study(attrs) do
    %Study{} |> Study.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Register a study from the exact bytes of an authored bundle.

  The hash is derived here rather than supplied, so a study cannot be created whose stated hash
  describes something other than what it will serve.
  """
  def create_study_from_bundle(name, source) when is_binary(source) do
    with {:ok, decoded} <- Jason.decode(source) do
      create_study(%{
        name: name,
        protocol_source: source,
        protocol: decoded,
        protocol_hash: Study.hash_of(source)
      })
    end
  end

  @doc "The bytes to serve for a study, byte-identical to what was registered."
  def fetch_protocol_source(id) do
    case Repo.one(from s in Study, where: s.id == ^id, select: s.protocol_source) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def add_join_code(%Study{} = study, code, arm \\ nil) do
    %JoinCode{}
    |> JoinCode.changeset(%{study_id: study.id, code: code, arm: arm})
    |> Repo.insert()
  end

  def get_study(id), do: Repo.get(Study, id)

  @doc """
  Look up a join code, case-insensitively.

  Codes get read off posters and out of text messages, so requiring exact capitalisation would fail
  participants for no reason.
  """
  def fetch_join_code(code) when is_binary(code) do
    query =
      from j in JoinCode,
        where: fragment("lower(?)", j.code) == ^String.downcase(code),
        preload: [:study]

    case Repo.one(query) do
      nil -> {:error, :no_such_study}
      join_code -> {:ok, join_code}
    end
  end

  def fetch_join_code(_), do: {:error, :no_such_study}
end
