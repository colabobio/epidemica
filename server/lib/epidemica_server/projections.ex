defmodule EpidemicaServer.Projections do
  @moduledoc """
  Derived tables built from the append-only observation store.

  Projections are always rebuildable. Nothing writes to them except this module, and dropping and
  rebuilding one must reproduce it exactly — that property is what makes the observation store the
  single source of truth rather than one copy of it among several.

  Only validated observations are projected. An observation quarantined pending a schema the server
  does not yet have has no reliable shape, so feeding it to a projection would corrupt the derived
  table; it is picked up by a rebuild after the schema arrives.
  """

  import Ecto.Query

  alias EpidemicaServer.Ingest.Observation
  alias EpidemicaServer.Repo

  @contact_episode "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json"
  @bands ~w(immediate close medium far)

  @doc "Project any not-yet-projected contact episodes. Safe to run repeatedly."
  def project_contacts(study_id \\ nil) do
    rows =
      contact_source_query(study_id)
      |> Repo.all()
      |> Enum.map(&contact_row/1)
      |> Enum.reject(&is_nil/1)

    {count, _} =
      Repo.insert_all("contacts", rows,
        on_conflict: :nothing,
        conflict_target: [:observation_id]
      )

    count
  end

  @doc """
  Drop and rebuild the contacts projection.

  The acceptance criterion for a projection is that this is indistinguishable from having built it
  incrementally all along.
  """
  def rebuild_contacts(study_id \\ nil) do
    case study_id do
      nil -> Repo.delete_all("contacts")
      id -> Repo.delete_all(from c in "contacts", where: c.study_id == type(^id, :binary_id))
    end

    project_contacts(study_id)
  end

  def count_contacts(study_id \\ nil) do
    query = from c in "contacts", select: count()

    query =
      if study_id, do: where(query, [c], c.study_id == type(^study_id, :binary_id)), else: query

    Repo.one(query)
  end

  defp contact_source_query(study_id) do
    query =
      from o in Observation,
        where: o.validated == true and o.schema_uri == @contact_episode,
        select: %{
          id: o.id,
          study_id: o.study_id,
          subject: o.subject,
          payload: o.payload
        }

    if study_id, do: where(query, [o], o.study_id == ^study_id), else: query
  end

  defp contact_row(%{payload: payload} = obs) when is_map(payload) do
    with {:ok, started_at} <- timestamp(payload["started_at"]),
         {:ok, ended_at} <- timestamp(payload["ended_at"]),
         bands when is_map(bands) <- payload["band_seconds"] do
      %{
        observation_id: obs.id,
        study_id: Ecto.UUID.dump!(obs.study_id),
        subject: obs.subject,
        peer: payload["peer"],
        pair_key: payload["pair_key"],
        started_at: started_at,
        ended_at: ended_at,
        duration_s: DateTime.diff(ended_at, started_at, :millisecond) / 1000,
        band_seconds: bands,
        observed_seconds: @bands |> Enum.map(&number(bands[&1])) |> Enum.sum(),
        sample_count: integer(payload["sample_count"]),
        gap_count: integer(payload["gap_count"])
      }
    else
      _ -> nil
    end
  end

  defp contact_row(_), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, %{dt | microsecond: {elem(dt.microsecond, 0), 6}}}
      _ -> :error
    end
  end

  defp timestamp(_), do: :error

  defp number(v) when is_number(v), do: v
  defp number(_), do: 0
  defp integer(v) when is_integer(v), do: v
  defp integer(_), do: nil
end
