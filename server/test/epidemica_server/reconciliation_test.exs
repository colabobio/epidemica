defmodule EpidemicaServer.ReconciliationTest do
  @moduledoc """
  Reconciling two asymmetric views of one encounter.

  Every case here is a way of getting the number wrong that would be invisible downstream: a pair
  that double-counts, a pair that vanishes, or a network that changes depending on who uploaded
  first.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Projections, Reconciliation, Repo}
  alias EpidemicaServer.Ingest.Observation

  @episode_uri "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json"
  @study_id "c0badf00-1111-4222-8333-444455556666"
  @day_start ~U[2026-09-02 00:00:00.000000Z]
  @day_end ~U[2026-09-03 00:00:00.000000Z]

  defp at(minutes), do: DateTime.add(@day_start, minutes * 60, :second)

  defp episode(reporter, peer, from_min, to_min, opts \\ []) do
    bands = Keyword.get(opts, :bands, %{"close" => (to_min - from_min) * 60})

    Repo.insert!(%Observation{
      study_id: @study_id,
      subject: reporter,
      device_id: Keyword.get(opts, :device_id, "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"),
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: @episode_uri,
      envelope_version: "1.0",
      observed_at: at(to_min),
      received_at: Keyword.get(opts, :received_at, DateTime.utc_now()),
      envelope: %{},
      payload: %{
        "peer" => peer,
        "started_at" => DateTime.to_iso8601(at(from_min)),
        "ended_at" => DateTime.to_iso8601(at(to_min)),
        "band_seconds" =>
          Map.merge(%{"immediate" => 0, "close" => 0, "medium" => 0, "far" => 0}, bands),
        "band_edges_m" => [1.0, 2.0, 5.0],
        "sample_count" => 10,
        "estimator" => "coarse_distance",
        "estimator_version" => "2.0.0"
      },
      validated: true
    })
  end

  defp network(opts \\ []) do
    Projections.project_contacts(@study_id)
    Reconciliation.network(@study_id, @day_start, @day_end, opts)
  end

  test "both sides of one encounter become one pair" do
    episode("alice-0001", "bob-0001", 10, 22)
    episode("bob-0001", "alice-0001", 12, 19)

    assert [pair] = network()
    assert pair.pair == {"alice-0001", "bob-0001"}
    assert pair.both_reported
    assert pair.episode_count == 2
  end

  test "intervals are unioned, not summed" do
    # A sees twelve minutes, B sees seven of the same twelve. Summing would report nineteen minutes
    # of contact from twelve minutes of encounter.
    episode("alice-0001", "bob-0001", 10, 22)
    episode("bob-0001", "alice-0001", 12, 19)

    assert [pair] = network()
    assert pair.seconds == 720.0
  end

  test "contact happened when either side saw it" do
    # Disjoint views of one encounter: neither device saw the whole of it.
    episode("alice-0001", "bob-0001", 0, 10)
    episode("bob-0001", "alice-0001", 20, 30)

    assert [pair] = network()
    # Intersecting would report nothing at all.
    assert pair.seconds == 1200.0
  end

  test "distance comes from the better-observed side, unmodified" do
    episode("alice-0001", "bob-0001", 0, 20, bands: %{"immediate" => 1200})
    episode("bob-0001", "alice-0001", 5, 10, bands: %{"far" => 300})

    assert [pair] = network()
    assert pair.reported_by == "alice-0001"
    assert pair.band_seconds["immediate"] == 1200.0
    assert pair.band_seconds["far"] == 0.0
  end

  test "band seconds never exceed the unioned duration" do
    # The invariant that makes the reconciled number safe to hand a transmission model.
    episode("alice-0001", "bob-0001", 0, 20, bands: %{"immediate" => 1200})
    episode("bob-0001", "alice-0001", 0, 20, bands: %{"far" => 1200})

    assert [pair] = network()
    assert Enum.sum(Map.values(pair.band_seconds)) <= pair.seconds
  end

  test "a one-sided report is kept and flagged" do
    episode("alice-0001", "bob-0001", 10, 22)

    assert [pair] = network()
    # Discarding it would lose real contact with a half-deaf pair; a study that wants to be strict
    # can filter on the flag, but cannot recover what was thrown away.
    refute pair.both_reported
    assert pair.seconds == 720.0
  end

  test "the result does not depend on who uploaded first" do
    episode("bob-0001", "alice-0001", 12, 19)
    episode("alice-0001", "bob-0001", 10, 22)
    first = network()

    Repo.delete_all("contacts")
    Repo.delete_all(Observation)

    episode("alice-0001", "bob-0001", 10, 22)
    episode("bob-0001", "alice-0001", 12, 19)
    second = network()

    assert first == second
  end

  test "a tie in coverage is broken deterministically" do
    episode("bob-0001", "alice-0001", 0, 10, bands: %{"close" => 600})
    episode("alice-0001", "bob-0001", 0, 10, bands: %{"close" => 600})

    assert [pair] = network()
    assert pair.reported_by == "alice-0001"
  end

  test "separate pairs stay separate" do
    episode("alice-0001", "bob-0001", 0, 10)
    episode("alice-0001", "carol-0001", 20, 30)
    episode("bob-0001", "carol-0001", 40, 50)

    pairs = Enum.map(network(), & &1.pair)

    assert pairs == [
             {"alice-0001", "bob-0001"},
             {"alice-0001", "carol-0001"},
             {"bob-0001", "carol-0001"}
           ]
  end

  test "repeated encounters with the same peer accumulate" do
    episode("alice-0001", "bob-0001", 0, 10)
    episode("alice-0001", "bob-0001", 60, 70)

    assert [pair] = network()
    assert pair.seconds == 1200.0
    assert pair.episode_count == 2
  end

  test "a late arrival never changes a network already computed" do
    early = ~U[2026-09-03 01:00:00.000000Z]
    episode("alice-0001", "bob-0001", 10, 22, received_at: ~U[2026-09-02 23:00:00.000000Z])

    as_computed = network(received_before: early)

    # A phone offline for two days uploads its contacts afterwards. The record gains them; the day
    # whose consequences participants were already told about does not.
    episode("bob-0001", "alice-0001", 12, 40, received_at: ~U[2026-09-04 09:00:00.000000Z])

    assert network(received_before: early) == as_computed
    assert [recomputed] = network()
    assert recomputed.seconds > hd(as_computed).seconds
  end

  test "a day with no contact is an empty network, not an error" do
    assert network() == []
  end
end
