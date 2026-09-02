defmodule EpidemicaServer.HealthTest do
  @moduledoc """
  Turning heartbeats into coverage.

  The rule under test is that anything not positively reported is unobserved. Every case here is a
  way of accidentally claiming coverage that was never asserted.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Health, Repo}
  alias EpidemicaServer.Ingest.Observation

  @status_uri "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"
  @study_id "c0badf00-1111-4222-8333-444455556666"
  @device_id "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"

  @from ~U[2026-09-02 00:00:00.000000Z]
  @to ~U[2026-09-03 00:00:00.000000Z]

  defp report(subject, state, start_hour, end_hour, seq) do
    Repo.insert!(%Observation{
      study_id: @study_id,
      subject: subject,
      device_id: @device_id,
      seq: seq,
      module: "proximity",
      schema_uri: @status_uri,
      envelope_version: "1.0",
      observed_at: DateTime.add(@from, end_hour * 3600, :second),
      received_at: DateTime.utc_now(),
      envelope: %{},
      payload: %{
        "state" => state,
        "window_start" => iso(start_hour),
        "window_end" => iso(end_hour)
      },
      validated: true
    })
  end

  defp iso(hour), do: @from |> DateTime.add(hour * 3600, :second) |> DateTime.to_iso8601()

  defp coverage(subject) do
    Health.coverage(@study_id, "proximity", @from, @to) |> Map.get(subject)
  end

  test "a full day of sensing is full coverage" do
    for hour <- 0..23, do: report("alice-0001", "sensing", hour, hour + 1, hour + 1)

    assert coverage("alice-0001") == 1.0
  end

  test "half a day of sensing is half coverage" do
    for hour <- 0..11, do: report("alice-0001", "sensing", hour, hour + 1, hour + 1)

    assert coverage("alice-0001") == 0.5
  end

  test "a gap in reports is uncovered, not assumed quiet" do
    # The core rule. A killed app reports nothing, and nothing must never read as sensing.
    report("alice-0001", "sensing", 0, 6, 1)
    report("alice-0001", "sensing", 18, 24, 2)

    assert coverage("alice-0001") == 0.5
  end

  test "radio off contributes no coverage even though it was reported" do
    report("alice-0001", "sensing", 0, 12, 1)
    report("alice-0001", "radio_off", 12, 24, 2)

    # Reported and observed are different claims. Only sensing asserts observation.
    assert coverage("alice-0001") == 0.5
  end

  test "a device never heard from is absent rather than zero" do
    report("alice-0001", "sensing", 0, 24, 1)

    covered = Health.coverage(@study_id, "proximity", @from, @to)

    # Absent and zero are different diagnoses: never heard from, versus heard from and off.
    refute Map.has_key?(covered, "bob-0001")
    assert covered["alice-0001"] == 1.0
  end

  test "a duplicated window is not counted twice" do
    # A retried batch delivers the same window again; summing raw durations would let a device
    # claim more coverage than the day contains.
    report("alice-0001", "sensing", 0, 12, 1)
    report("alice-0001", "sensing", 0, 12, 2)

    assert coverage("alice-0001") == 0.5
  end

  test "overlapping windows are unioned, not summed" do
    report("alice-0001", "sensing", 0, 8, 1)
    report("alice-0001", "sensing", 4, 12, 2)

    assert coverage("alice-0001") == 0.5
  end

  test "windows are clipped to the period asked about" do
    report("alice-0001", "sensing", -12, 12, 1)

    assert coverage("alice-0001") == 0.5
  end

  test "a window entirely outside the period contributes nothing" do
    report("alice-0001", "sensing", 24, 36, 1)

    refute Map.has_key?(Health.coverage(@study_id, "proximity", @from, @to), "alice-0001")
  end

  test "another module's status does not count as proximity coverage" do
    report("alice-0001", "sensing", 0, 24, 1)

    other =
      Repo.insert!(%Observation{
        study_id: @study_id,
        subject: "bob-0001",
        device_id: @device_id,
        seq: 99,
        module: "instruments",
        schema_uri: @status_uri,
        envelope_version: "1.0",
        observed_at: @to,
        received_at: DateTime.utc_now(),
        envelope: %{},
        payload: %{"state" => "sensing", "window_start" => iso(0), "window_end" => iso(24)},
        validated: true
      })

    assert other.module == "instruments"
    refute Map.has_key?(Health.coverage(@study_id, "proximity", @from, @to), "bob-0001")
  end

  test "insufficiently observed includes everyone never heard from" do
    report("alice-0001", "sensing", 0, 24, 1)
    report("bob-0001", "sensing", 0, 6, 2)

    below =
      Health.insufficiently_observed(@study_id, "proximity", @from, @to, 0.5, [
        "alice-0001",
        "bob-0001",
        "carol-0001"
      ])

    # carol never reported at all -- the case a naive query joining on observations would miss,
    # and the one where treating silence as observation is most damaging.
    assert below == ["bob-0001", "carol-0001"]
  end
end
