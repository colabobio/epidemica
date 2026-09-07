defmodule EpidemicaServer.Ingest do
  @moduledoc """
  Batch ingest of observations.

  Implements `contracts/api/ingest/v1.yaml`. Two rules from ADR-0002 drive the whole design:

  * **Schema problems never lose data.** An observation this build cannot validate is stored with
    `validated: false` and reported as quarantined. A newer client can outrun a server upgrade, and
    field deployments are usually the last thing updated, so rejecting would destroy data that
    cannot be recollected.
  * **Delivery is idempotent.** `(device_id, seq)` is a unique key, so a retry after an ambiguous
    failure is always safe and is reported as a duplicate.

  Only an observation whose identifying fields cannot be read is *rejected*, because there is no key
  under which to store it. Even then the client is told to keep it rather than discard it.
  """

  import Ecto.Query

  alias EpidemicaServer.{Contracts, Projections, Repo, Studies}
  alias EpidemicaServer.Ingest.Observation

  @max_batch 1000

  defmodule Auth do
    @moduledoc "The device and study a token authorises."
    defstruct [:study_id, :subject, :device_id]
  end

  @doc """
  Ingest a batch of envelopes on behalf of an authenticated device.

  Returns `{:ok, result}` or `{:error, reason}` where reason is `:too_large`, `:empty`,
  `:heterogeneous_batch` (a 400) or `:forbidden` (a 403).
  """
  def submit(%Auth{} = auth, envelopes) when is_list(envelopes) do
    # Binding is checked before schema validation, and that ordering matters. An envelope naming a
    # subject the token does not authorise is refused outright rather than quarantined, because
    # quarantining would store a row attributed to a subject the server cannot vouch for — which is
    # the mis-attribution this check exists to prevent, merely with `validated: false` on it.
    with :ok <- check_size(envelopes),
         :ok <- check_batch_binding(auth, envelopes) do
      received_at = DateTime.utc_now()

      classified = Enum.with_index(envelopes) |> Enum.map(&classify(&1, auth, received_at))

      {storable, rejected} = Enum.split_with(classified, &(&1.status != :rejected))
      {inserted, ids} = insert(storable)

      # The derived tables are built here rather than left for a reader to remember. An empty
      # `contacts` is indistinguishable from a study where nobody met anyone, so a projection that
      # only runs when something happens to ask for it is a silent wrong answer.
      Projections.project_contacts(auth.study_id, only: ids)
      refresh_study_state(auth)

      {:ok, build_result(classified, storable, rejected, inserted, received_at)}
    end
  end

  # A scored study tells the participant what has been recorded since the last tick, so a contact
  # is visible while it is happening rather than only in the next day's arithmetic. Only the
  # uploading participant is refreshed; their peer picks the same contact up on their own next sync.
  defp refresh_study_state(%Auth{} = auth) do
    case Studies.get_study(auth.study_id) do
      %{protocol: %{"rules" => %{"engine" => "epigame"}}} ->
        EpidemicaServer.Epigame.refresh_pending(auth.study_id, auth.subject)

      _ ->
        :ok
    end
  end

  defp check_size([]), do: {:error, :empty}
  defp check_size(list) when length(list) > @max_batch, do: {:error, :too_large}
  defp check_size(_), do: :ok

  # A batch is homogeneous and must match the token on all three identifiers. Checking device and
  # study but not subject would still let a device write observations attributed to another
  # participant in the same study, which is the mis-attribution this check exists to prevent.
  defp check_batch_binding(auth, envelopes) do
    devices = distinct_values(envelopes, "device_id")
    studies = distinct_values(envelopes, "study_id")
    subjects = distinct_values(envelopes, "subject")

    cond do
      length(devices) > 1 or length(studies) > 1 or length(subjects) > 1 ->
        {:error, :heterogeneous_batch}

      devices != [auth.device_id] ->
        {:error, :forbidden}

      studies != [auth.study_id] ->
        {:error, :forbidden}

      subjects != [auth.subject] ->
        {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp distinct_values(envelopes, key) do
    envelopes
    |> Enum.map(fn
      envelope when is_map(envelope) -> Map.get(envelope, key)
      _ -> nil
    end)
    |> Enum.uniq()
  end

  # -- classification ---------------------------------------------------------------------------

  defp classify({envelope, index}, auth, received_at) do
    with {:ok, device_id, seq} <- identifying_fields(envelope) do
      {status, reason, detail} = validate(envelope)

      %{
        index: index,
        seq: seq,
        status: status,
        reason: reason,
        detail: detail,
        row: row(envelope, auth, device_id, seq, received_at, status, reason, detail)
      }
    else
      {:error, detail} ->
        %{
          index: index,
          seq: nil,
          status: :rejected,
          reason: :unparseable,
          detail: detail,
          row: nil
        }
    end
  end

  # Without a usable (device_id, seq) there is no idempotency key, so there is nowhere to put the
  # observation and no way to recognise a retry of it.
  defp identifying_fields(envelope) when is_map(envelope) do
    with {:ok, device_id} <- uuid(Map.get(envelope, "device_id")),
         {:ok, seq} <- seq(Map.get(envelope, "seq")) do
      {:ok, device_id, seq}
    end
  end

  defp identifying_fields(_), do: {:error, "envelope is not an object"}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "device_id is not a UUID"}
    end
  end

  defp uuid(_), do: {:error, "device_id is missing"}

  defp seq(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp seq(value) when is_integer(value), do: {:error, "seq must not be negative"}
  defp seq(_), do: {:error, "seq is missing or not an integer"}

  defp validate(envelope) do
    version = Map.get(envelope, "envelope_version")

    cond do
      version not in Contracts.envelope_versions() ->
        {:quarantined, :unknown_envelope_version, "envelope_version #{inspect(version)}"}

      match?({:error, _}, Contracts.validate_envelope(envelope)) ->
        {:error, error} = Contracts.validate_envelope(envelope)
        {:quarantined, :envelope_invalid, describe(error)}

      true ->
        validate_payload(envelope)
    end
  end

  defp validate_payload(envelope) do
    schema_uri = Map.get(envelope, "schema_uri")
    payload = Map.get(envelope, "payload")

    case Contracts.validate_payload(schema_uri, payload) do
      :ok ->
        {:accepted, nil, nil}

      {:error, :unknown_payload_schema} ->
        {:quarantined, :unknown_payload_schema, "no local contract for #{schema_uri}"}

      {:error, error} ->
        {:quarantined, :payload_invalid, describe(error)}
    end
  end

  defp describe(error) when is_list(error) do
    error
    |> Keyword.take([:instance_location, :absolute_keyword_location, :expected])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> String.slice(0, 1024)
  end

  defp describe(other), do: other |> inspect() |> String.slice(0, 1024)

  # -- persistence ------------------------------------------------------------------------------

  defp row(envelope, auth, device_id, seq, received_at, status, reason, detail) do
    %{
      study_id: auth.study_id,
      subject: Map.get(envelope, "subject") || auth.subject,
      device_id: device_id,
      seq: seq,
      module: string(Map.get(envelope, "module")),
      schema_uri: string(Map.get(envelope, "schema_uri")),
      envelope_version: string(Map.get(envelope, "envelope_version")),
      protocol_hash: string(Map.get(envelope, "protocol_hash")),
      observed_at: timestamp(Map.get(envelope, "observed_at")),
      clock_offset_ms: integer(Map.get(envelope, "clock_offset_ms")),
      received_at: received_at,
      envelope: envelope,
      payload: map_or_nil(Map.get(envelope, "payload")),
      validated: status == :accepted,
      validation_reason: reason && Atom.to_string(reason),
      validation_detail: detail
    }
  end

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil
  defp integer(v) when is_integer(v), do: v
  defp integer(_), do: nil
  defp map_or_nil(v) when is_map(v), do: v
  defp map_or_nil(_), do: nil

  # The contract allows fractional seconds of any length, so "…:22.481Z" arrives with millisecond
  # precision while the column demands microsecond. The value is already correct; only the declared
  # precision needs normalising.
  defp timestamp(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  # `on_conflict: :nothing` makes a retry a no-op; the returned keys tell us which rows were new,
  # and everything else in the batch was therefore already held.
  defp insert([]), do: {MapSet.new(), []}

  defp insert(storable) do
    rows = Enum.map(storable, & &1.row)

    {_count, returned} =
      Repo.insert_all(Observation, rows,
        on_conflict: :nothing,
        conflict_target: [:device_id, :seq],
        returning: [:id, :seq]
      )

    {MapSet.new(returned, & &1.seq), Enum.map(returned, & &1.id)}
  end

  defp build_result(classified, storable, rejected, inserted, received_at) do
    outcomes =
      Enum.map(storable, fn item ->
        if MapSet.member?(inserted, item.seq) do
          %{item | status: item.status}
        else
          %{item | status: :duplicate, reason: nil, detail: nil}
        end
      end) ++ rejected

    counts = Enum.frequencies_by(outcomes, & &1.status)

    accepted_seqs =
      outcomes |> Enum.filter(&(&1.status == :accepted)) |> Enum.map(& &1.seq)

    %{
      received: length(classified),
      accepted: Map.get(counts, :accepted, 0),
      duplicate: Map.get(counts, :duplicate, 0),
      quarantined: Map.get(counts, :quarantined, 0),
      rejected: Map.get(counts, :rejected, 0),
      highest_seq_accepted: if(accepted_seqs == [], do: nil, else: Enum.max(accepted_seqs)),
      exceptions:
        outcomes
        |> Enum.reject(&(&1.status == :accepted))
        |> Enum.sort_by(& &1.index)
        |> Enum.map(&exception/1),
      server_time: received_at
    }
  end

  defp exception(item) do
    %{index: item.index, seq: item.seq, status: Atom.to_string(item.status)}
    |> maybe_put(:reason, item.reason && Atom.to_string(item.reason))
    |> maybe_put(:detail, item.detail)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- watermark --------------------------------------------------------------------------------

  @doc """
  What the server holds for a device.

  `highest_contiguous_seq` is the value a client may safely prune below. Pruning below
  `highest_seq` instead would discard observations sitting behind a gap.
  """
  def watermark(%Auth{} = auth) do
    seqs =
      from(o in Observation,
        where: o.device_id == ^auth.device_id and o.study_id == ^auth.study_id,
        select: o.seq,
        order_by: o.seq
      )
      |> Repo.all()

    %{
      device_id: auth.device_id,
      study_id: auth.study_id,
      highest_seq: List.last(seqs),
      highest_contiguous_seq: highest_contiguous(seqs),
      accepted_count: count_where(auth, true),
      quarantined_count: count_where(auth, false),
      server_time: DateTime.utc_now()
    }
  end

  # A device's stream begins at whatever `seq` it first allocated, which the server is never told.
  # Both origins a fresh counter can have are accepted: the envelope permits 0, and the reference
  # client's outbox is SQLite `AUTOINCREMENT`, whose first row is 1. Assuming one of them is how
  # this endpoint came to answer `nil` for every real device.
  #
  # A run starting higher is refused rather than read as an already-pruned prefix. It cannot be
  # told apart from a client whose earlier batch failed while a later one succeeded, and answering
  # there would tell that client to discard observations it still owes.
  @seq_origins [0, 1]

  defp highest_contiguous([]), do: nil
  defp highest_contiguous([first | _]) when first not in @seq_origins, do: nil

  defp highest_contiguous([first | rest]) do
    Enum.reduce_while(rest, first, fn seq, acc ->
      cond do
        seq == acc + 1 -> {:cont, seq}
        seq == acc -> {:cont, acc}
        true -> {:halt, acc}
      end
    end)
  end

  defp count_where(auth, validated) do
    from(o in Observation,
      where:
        o.device_id == ^auth.device_id and o.study_id == ^auth.study_id and
          o.validated == ^validated,
      select: count()
    )
    |> Repo.one()
  end
end
