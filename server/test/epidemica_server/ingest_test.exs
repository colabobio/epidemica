defmodule EpidemicaServer.IngestTest do
  @moduledoc """
  Ingest behaviour, driven from `contracts/fixtures/` so that the tests and the contracts cannot
  drift apart.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.Ingest
  alias EpidemicaServer.Ingest.Auth

  @contracts_dir Path.expand("../../../contracts", __DIR__)

  @study_id "5f3a1c4e-2b7d-4a91-8e6f-0c1d2e3f4a5b"
  @device_id "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"
  @subject "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6"

  defp auth, do: %Auth{study_id: @study_id, device_id: @device_id, subject: @subject}

  defp fixtures(kind) do
    cases =
      @contracts_dir
      |> Path.join("fixtures/observations/envelope/#{kind}.json")
      |> File.read!()
      |> Jason.decode!()

    refute Enum.empty?(cases), "no #{kind} envelope fixtures found"
    Enum.map(cases, & &1["instance"])
  end

  # Fixtures reuse the same seq, which is realistic for illustrating a schema but not for a batch,
  # where seq is the idempotency key. Renumbering keeps each fixture a distinct observation.
  defp renumbered(envelopes) do
    envelopes
    |> Enum.with_index()
    |> Enum.map(fn {envelope, i} ->
      if is_map(envelope), do: Map.put(envelope, "seq", i), else: envelope
    end)
  end

  # One invalid fixture's defect *is* its subject, which the binding check catches before schema
  # validation ever runs. It is exercised separately as a forbidden batch; mixing it in here would
  # test the binding check while appearing to test quarantine.
  defp bindable_invalid_fixtures do
    fixtures = Enum.filter(fixtures("invalid"), &(is_map(&1) and &1["subject"] == @subject))
    refute Enum.empty?(fixtures)
    renumbered(fixtures)
  end

  describe "valid fixtures" do
    test "are all accepted and stored" do
      envelopes = renumbered(fixtures("valid"))
      {:ok, result} = Ingest.submit(auth(), envelopes)

      assert result.accepted == length(envelopes) - result.quarantined
      assert result.rejected == 0
      assert result.duplicate == 0
    end

    test "a payload with a known schema is validated and marked so" do
      envelope =
        fixtures("valid")
        |> Enum.find(&(&1["module"] == "proximity"))
        |> Map.put("seq", 0)

      {:ok, result} = Ingest.submit(auth(), [envelope])

      assert result.accepted == 1
      assert result.exceptions == []
      assert [%{validated: true, module: "proximity"}] = all_observations()
    end

    test "a payload whose schema this build does not know is quarantined, not lost" do
      envelope =
        fixtures("valid")
        |> Enum.find(&String.contains?(&1["schema_uri"], "pollen"))
        |> Map.put("seq", 0)

      {:ok, result} = Ingest.submit(auth(), [envelope])

      assert result.quarantined == 1
      assert [%{"reason" => "unknown_payload_schema", "status" => "quarantined"}] = stringify(result.exceptions)
      assert [%{validated: false, payload: %{"grains_per_m3" => 42}}] = all_observations()
    end
  end

  describe "invalid fixtures" do
    test "are never rejected wholesale and never raise" do
      for envelope <- bindable_invalid_fixtures() do
        assert {:ok, _result} = Ingest.submit(auth(), [envelope])
      end
    end

    test "are stored rather than discarded, except when unidentifiable" do
      envelopes = bindable_invalid_fixtures()
      {:ok, result} = Ingest.submit(auth(), envelopes)

      assert result.accepted == 0
      assert result.quarantined + result.rejected == length(envelopes)
      # Everything storable was in fact stored.
      assert length(all_observations()) == result.quarantined
    end

    test "a subject the token does not authorise is refused, not quarantined" do
      envelope =
        fixtures("invalid")
        |> Enum.find(&(is_map(&1) and &1["subject"] != @subject))
        |> Map.put("seq", 0)

      assert {:error, :forbidden} = Ingest.submit(auth(), [envelope])
      assert all_observations() == []
    end

    test "a future envelope version is quarantined as a version lag, not a defect" do
      envelope = fixtures("valid") |> hd() |> Map.merge(%{"envelope_version" => "1.1", "seq" => 0})
      {:ok, result} = Ingest.submit(auth(), [envelope])

      assert [%{"reason" => "unknown_envelope_version"}] = stringify(result.exceptions)
    end

    test "a negative seq is rejected, because it cannot serve as an idempotency key" do
      envelope = fixtures("valid") |> hd() |> Map.put("seq", -1)
      {:ok, result} = Ingest.submit(auth(), [envelope])

      assert result.rejected == 1
      assert [%{"status" => "rejected", "reason" => "unparseable"}] = stringify(result.exceptions)
      assert all_observations() == []
    end
  end

  describe "idempotency" do
    test "resending a delivered batch reports duplicates and stores nothing twice" do
      envelopes = renumbered(fixtures("valid"))

      {:ok, first} = Ingest.submit(auth(), envelopes)
      {:ok, second} = Ingest.submit(auth(), envelopes)

      assert second.duplicate == length(envelopes)
      assert second.accepted == 0
      assert length(all_observations()) == first.accepted + first.quarantined
    end

    test "a partially delivered batch resolves correctly on retry" do
      [a, b, c] = renumbered(fixtures("valid")) |> Enum.take(3)

      {:ok, _} = Ingest.submit(auth(), [a, b])
      {:ok, result} = Ingest.submit(auth(), [a, b, c])

      assert result.duplicate == 2
      assert result.accepted + result.quarantined == 1
    end
  end

  describe "batch binding" do
    test "a device_id disagreeing with the token is forbidden and stores nothing" do
      envelope =
        fixtures("valid")
        |> hd()
        |> Map.merge(%{"device_id" => "99999999-9999-4999-8999-999999999999", "seq" => 0})

      assert {:error, :forbidden} = Ingest.submit(auth(), [envelope])
      assert all_observations() == []
    end

    test "a study_id disagreeing with the token is forbidden" do
      envelope =
        fixtures("valid")
        |> hd()
        |> Map.merge(%{"study_id" => "99999999-9999-4999-8999-999999999999", "seq" => 0})

      assert {:error, :forbidden} = Ingest.submit(auth(), [envelope])
    end

    test "a batch mixing devices is a bad request" do
      [a, b] = renumbered(fixtures("valid")) |> Enum.take(2)
      b = Map.put(b, "device_id", "99999999-9999-4999-8999-999999999999")

      assert {:error, :heterogeneous_batch} = Ingest.submit(auth(), [a, b])
    end

    test "an empty batch and an oversized batch are both refused" do
      assert {:error, :empty} = Ingest.submit(auth(), [])

      oversized = List.duplicate(fixtures("valid") |> hd(), 1001) |> renumbered()
      assert {:error, :too_large} = Ingest.submit(auth(), oversized)
    end
  end

  describe "watermark" do
    test "reports the contiguous high-water mark, not the maximum" do
      envelopes = renumbered(fixtures("valid"))
      [a, b, _c, d] = envelopes

      # Deliver 0, 1 and 3 — leaving a gap at 2.
      {:ok, _} = Ingest.submit(auth(), [a, b, d])
      mark = Ingest.watermark(auth())

      assert mark.highest_seq == 3
      assert mark.highest_contiguous_seq == 1
    end

    test "is empty for a device that has sent nothing" do
      mark = Ingest.watermark(auth())
      assert mark.highest_seq == nil
      assert mark.highest_contiguous_seq == nil
    end
  end

  defp all_observations do
    EpidemicaServer.Repo.all(EpidemicaServer.Ingest.Observation)
  end

  defp stringify(exceptions) do
    Enum.map(exceptions, fn e -> Map.new(e, fn {k, v} -> {Atom.to_string(k), v} end) end)
  end
end
