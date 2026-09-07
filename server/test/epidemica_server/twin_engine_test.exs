defmodule EpidemicaServer.TwinEngineTest do
  @moduledoc """
  The twin against the real engine.

  Everything else about the twin is tested with a stand-in, which proves the orchestration but not
  that the two halves agree. These tests run Starsim for real, because the contract between Elixir
  and Python is a shape neither side validates and a mismatch would show up as an epidemic that
  quietly does nothing.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Projections, Repo, Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Ingest.Observation

  @episode_uri "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json"
  @status_uri "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"
  @day_start ~U[2026-09-02 00:00:00.000000Z]
  @day_end ~U[2026-09-03 00:00:00.000000Z]

  setup do
    unless File.dir?(models_dir()) do
      raise "models directory not found at #{models_dir()}"
    end

    :ok
  end

  defp models_dir, do: Application.get_env(:epidemica_server, :twin)[:models_dir]

  defp study(twin) do
    twin =
      Map.merge(
        %{
          "engine" => "starsim",
          "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
          "population" => 6
        },
        twin
      )

    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Engine study",
        "modules" => %{"proximity" => %{}},
        "twin" => twin
      })

    {:ok, study} = Studies.create_study_from_bundle("engine study", source)
    study
  end

  defp participant(study, subject) do
    Repo.insert!(%Participant{study_id: study.id, subject: subject, enrolled_at: @day_start})
    sensing(study, subject)
  end

  defp sensing(study, subject) do
    Repo.insert!(%Observation{
      study_id: study.id,
      subject: subject,
      device_id: "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: @status_uri,
      envelope_version: "1.0",
      observed_at: @day_end,
      received_at: DateTime.utc_now(),
      envelope: %{},
      payload: %{
        "state" => "sensing",
        "window_start" => DateTime.to_iso8601(@day_start),
        "window_end" => DateTime.to_iso8601(@day_end)
      },
      validated: true
    })
  end

  defp episode(study, reporter, peer, minutes) do
    Repo.insert!(%Observation{
      study_id: study.id,
      subject: reporter,
      device_id: "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: @episode_uri,
      envelope_version: "1.0",
      observed_at: DateTime.add(@day_start, minutes * 60, :second),
      received_at: DateTime.utc_now(),
      envelope: %{},
      payload: %{
        "peer" => peer,
        "started_at" => DateTime.to_iso8601(@day_start),
        "ended_at" => DateTime.to_iso8601(DateTime.add(@day_start, minutes * 60, :second)),
        "band_seconds" => %{
          "immediate" => minutes * 60,
          "close" => 0,
          "medium" => 0,
          "far" => 0
        },
        "band_edges_m" => [1.0, 2.0, 5.0],
        "sample_count" => 10,
        "estimator" => "coarse_distance",
        "estimator_version" => "2.0.0"
      },
      validated: true
    })

    Projections.project_contacts(study.id)
  end

  defp infect!(study, subject, day \\ 0) do
    agent = Repo.get_by!(EpidemicaServer.Twin.Agent, study_id: study.id, subject: subject)

    Repo.update!(
      EpidemicaServer.Twin.Agent.changeset(agent, %{state: "infected", infected_on_day: day})
    )
  end

  defp run(study, day),
    do: Twin.run_tick(study.id, day, anchor: @day_start, allow_incomplete: true)

  test "a measured contact with an infected participant can transmit, and says why" do
    s = study(%{"pars" => %{"diseases" => %{"beta" => 0.99}}, "population" => 2})
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    episode(s, "alice-0001", "bob-0001", 60)

    # Seed the outbreak, then let a real Starsim step decide what a full hour at arm's length does.
    Twin.reconcile_roster(s.id, %{"population" => 2}, 1)
    infect!(s, "alice-0001")

    {:ok, tick} = run(s, 1)

    bob = Enum.find(tick.outputs["agents"], &(&1["subject"] == "bob-0001"))
    assert bob["state"] == "infected"
    assert bob["newly_infected"] == true

    # Every infection has to be explicable: a participant told they caught something is owed an
    # account of where it came from.
    assert bob["infection"]["cause"] == "measured_contact"
    assert [%{"subject" => "alice-0001"}] = bob["infection"]["sources"]
  end

  test "the engine's version is what actually gets recorded" do
    s = study(%{"population" => 2})
    participant(s, "alice-0001")

    {:ok, tick} = run(s, 1)

    assert tick.engine == "starsim"
    assert tick.engine_version =~ ~r/^\d+\.\d+/
  end

  test "a stored tick reproduces exactly when replayed through the real engine" do
    s = study(%{"pars" => %{"diseases" => %{"beta" => 0.5}}, "population" => 8})
    for i <- 1..4, do: participant(s, "p-000#{i}")
    Twin.reconcile_roster(s.id, %{"population" => 8}, 1)
    infect!(s, "p-0001")
    episode(s, "p-0001", "p-0002", 45)

    {:ok, _} = run(s, 1)

    # The claim the whole record exists to support: the study's history can be checked, not merely
    # trusted. If this ever fails, every result the study reported is unverifiable.
    assert :ok = Twin.verify_tick(s.id, 1)
  end

  test "the virtual population mixes and can seed the real one" do
    s =
      study(%{
        "population" => 30,
        "pars" => %{
          "diseases" => %{"beta" => 0.9},
          "virtual" => %{"contacts_per_day" => 8, "band_seconds" => %{"immediate" => 3600}}
        }
      })

    participant(s, "alice-0001")
    Twin.reconcile_roster(s.id, %{"population" => 30}, 1)

    # Infect only virtual agents: with no measured contacts at all, any infection among the real
    # participants can only have arrived through the simulated population.
    for agent <- Twin.agents(s.id) |> Enum.filter(& &1.virtual) |> Enum.take(10) do
      Repo.update!(
        EpidemicaServer.Twin.Agent.changeset(agent, %{state: "infected", infected_on_day: 0})
      )
    end

    {:ok, tick} = run(s, 1)

    assert tick.outputs["newly_infected"] > 0

    causes =
      tick.outputs["agents"]
      |> Enum.filter(& &1["newly_infected"])
      |> Enum.map(& &1["infection"]["cause"])
      |> Enum.uniq()

    assert causes == ["virtual_population"]
  end
end
