defmodule EpidemicaServer.ProjectionsTest do
  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Ingest, Projections, Repo}
  alias EpidemicaServer.Ingest.Auth

  @contracts_dir Path.expand("../../../contracts", __DIR__)
  @study_id "5f3a1c4e-2b7d-4a91-8e6f-0c1d2e3f4a5b"
  @device_id "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"
  @subject "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6"

  defp auth, do: %Auth{study_id: @study_id, device_id: @device_id, subject: @subject}

  defp episode_payloads do
    payloads =
      @contracts_dir
      |> Path.join("fixtures/observations/proximity/contact_episode/valid.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(& &1["instance"])

    refute Enum.empty?(payloads)
    payloads
  end

  defp ingest_episodes do
    envelopes =
      episode_payloads()
      |> Enum.with_index()
      |> Enum.map(fn {payload, i} ->
        %{
          "envelope_version" => "1.0",
          "study_id" => @study_id,
          "protocol_hash" =>
            "sha256:9f2b7c1d4e6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c",
          "subject" => @subject,
          "device_id" => @device_id,
          "module" => "proximity",
          "schema_uri" =>
            "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json",
          "observed_at" => "2026-08-11T14:03:22.481Z",
          "clock_offset_ms" => 0,
          "seq" => i,
          "payload" => payload
        }
      end)

    {:ok, result} = Ingest.submit(auth(), envelopes)
    result
  end

  test "ingesting an episode projects it, without anyone asking" do
    result = ingest_episodes()
    assert result.accepted > 0

    # An empty `contacts` is indistinguishable from a study where nobody met anyone. Leaving the
    # projection for a reader to remember to run makes that silence the default answer.
    assert Projections.count_contacts() == result.accepted
  end

  test "a later projection finds nothing left to do" do
    result = ingest_episodes()

    assert Projections.project_contacts() == 0
    assert Projections.count_contacts() == result.accepted
  end

  test "is idempotent: projecting twice does not duplicate" do
    ingest_episodes()

    first = Projections.count_contacts()
    assert Projections.project_contacts() == 0
    assert Projections.count_contacts() == first
  end

  test "only considers episodes it has not already projected" do
    ingest_episodes()

    # The projection used to rebuild every episode in the study on each call and lean on the unique
    # index to throw the work away, which grows without bound over a study's life.
    orphan = Repo.one(from c in "contacts", select: c.observation_id, limit: 1)
    Repo.delete_all(from c in "contacts", where: c.observation_id == ^orphan)

    assert Projections.project_contacts() == 1
  end

  test "a rebuild reproduces the projection exactly" do
    ingest_episodes()

    before = snapshot()
    assert before != []

    Projections.rebuild_contacts()

    assert snapshot() == before
  end

  test "quarantined observations are not projected" do
    envelope = %{
      "envelope_version" => "1.0",
      "study_id" => @study_id,
      "protocol_hash" =>
        "sha256:9f2b7c1d4e6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c",
      "subject" => @subject,
      "device_id" => @device_id,
      "module" => "proximity",
      "schema_uri" =>
        "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json",
      "observed_at" => "2026-08-11T14:03:22.481Z",
      "clock_offset_ms" => 0,
      "seq" => 0,
      # Missing required bands, so the payload fails its contract and is quarantined.
      "payload" => %{"peer" => "c9e2f1a0-6b3d-4c88-9a71-2f3e4d5c6b7a"}
    }

    {:ok, result} = Ingest.submit(auth(), [envelope])
    assert result.quarantined == 1

    assert Projections.project_contacts() == 0
    assert Projections.count_contacts() == 0
  end

  test "observed_seconds sums the bands rather than trusting wall-clock duration" do
    ingest_episodes()
    Projections.project_contacts()

    for row <- snapshot() do
      bands = row.band_seconds |> Map.values() |> Enum.sum()
      assert_in_delta row.observed_seconds, bands, 0.001
      # Gaps mean observed time can be less than elapsed time; it must never be more.
      assert row.observed_seconds <= row.duration_s + 0.001
    end
  end

  defp snapshot do
    import Ecto.Query

    Repo.all(
      from c in "contacts",
        order_by: c.observation_id,
        select: %{
          observation_id: c.observation_id,
          subject: c.subject,
          peer: c.peer,
          duration_s: c.duration_s,
          observed_seconds: c.observed_seconds,
          band_seconds: c.band_seconds
        }
    )
  end
end
