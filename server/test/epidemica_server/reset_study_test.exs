defmodule EpidemicaServer.ResetStudyTest do
  @moduledoc """
  Resetting a study forgets what it decided and keeps what it observed.

  The distinction is the whole point. Observations are the system of record, so a replay has to run
  against exactly the data the phones reported; ticks and scores are derived, so removing them must
  leave nothing behind that a re-run would trip over.
  """

  use EpidemicaServer.DataCase, async: false

  alias EpidemicaServer.{Epigame, Projections, Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Ingest.Observation

  @starts_at ~U[2020-01-01 00:00:00.000000Z]
  @episode "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json"
  @status "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"

  defp study do
    protocol = %{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "title" => "Resettable",
      "modules" => %{"proximity" => %{}},
      "schedule" => %{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7},
      "twin" => %{
        "engine" => "starsim",
        "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
        "tick_interval_seconds" => 300,
        "population" => 4
      },
      "rules" => %{"engine" => "epigame", "pars" => %{"contact_min_seconds" => 60}}
    }

    {:ok, study} = Studies.create_study_from_bundle("resettable", Jason.encode!(protocol))
    study
  end

  defp observation(study, subject, schema_uri, payload, at) do
    Repo.insert!(%Observation{
      study_id: study.id,
      subject: subject,
      device_id: Ecto.UUID.generate(),
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: schema_uri,
      envelope_version: "1.0",
      protocol_hash: study.protocol_hash,
      observed_at: at,
      received_at: at,
      envelope: %{},
      payload: payload,
      validated: true
    })
  end

  defp populate(study) do
    for subject <- ~w(alice-0001 bob-0001) do
      Repo.insert!(%Participant{study_id: study.id, subject: subject, enrolled_at: @starts_at})
    end

    ended = DateTime.add(@starts_at, 240, :second)

    for {subject, peer} <- [{"alice-0001", "bob-0001"}, {"bob-0001", "alice-0001"}] do
      observation(
        study,
        subject,
        @episode,
        %{
          "peer" => peer,
          "started_at" => DateTime.to_iso8601(@starts_at),
          "ended_at" => DateTime.to_iso8601(ended),
          "band_seconds" => %{"immediate" => 100, "close" => 100, "medium" => 40, "far" => 0},
          "sample_count" => 24,
          "gap_count" => 0
        },
        ended
      )

      observation(
        study,
        subject,
        @status,
        %{
          "state" => "sensing",
          "window_start" => DateTime.to_iso8601(@starts_at),
          "window_end" => DateTime.to_iso8601(DateTime.add(@starts_at, 300, :second))
        },
        ended
      )
    end

    Projections.project_contacts(study.id)
    # Outside day 1's window, so the day still awards contacts and there is still an action to
    # check the reset's treatment of.
    Epigame.protect(study.id, "alice-0001", DateTime.add(@starts_at, 300, :second), %{})
    {:ok, _} = Twin.run_tick(study.id, 1, runner: stub())
    {:ok, _} = Epigame.settle_day(study.id, 1)
  end

  defp stub do
    fn inputs ->
      {:ok,
       %{
         "day" => inputs["day"],
         "engine" => "starsim",
         "engine_version" => "3.6.1",
         "seed" => inputs["seed"],
         "newly_infected" => 0,
         "total_cases" => inputs["total_cases_before"],
         "agents" =>
           Enum.map(inputs["agents"], fn a ->
             Map.take(a, ["index", "subject", "virtual", "state"])
             |> Map.merge(%{
               "newly_infected" => false,
               "infected_on_day" => a["infected_on_day"],
               "recovers_on_day" => a["recovers_on_day"],
               "dies_on_day" => a["dies_on_day"]
             })
           end)
       }}
    end
  end

  defp count(table, study_id) do
    Repo.one(from r in table, where: r.study_id == type(^study_id, :binary_id), select: count())
  end

  defp reset(study_id) do
    Mix.Tasks.Epidemica.ResetStudy.run(["--study", study_id, "--yes"])
  end

  describe "resetting" do
    test "removes everything the study decided" do
      study = study()
      populate(study)

      assert count("twin_ticks", study.id) == 1
      assert count("twin_agents", study.id) == 4
      assert count("game_ledger", study.id) == 2
      assert count("game_contact_awards", study.id) == 2
      assert count("game_actions", study.id) == 1
      assert count("participant_states", study.id) == 2

      capture_io(fn -> reset(study.id) end)

      for table <- ~w(twin_ticks twin_agents game_ledger game_contact_awards
                      participant_states) do
        assert count(table, study.id) == 0, "#{table} was not cleared"
      end
    end

    test "keeps protection decisions, because a participant made them" do
      study = study()
      populate(study)

      capture_io(fn -> reset(study.id) end)

      # A protect action is input, not a derived result. Dropping it would make a replay score a
      # different game from the one the participant played.
      assert count("game_actions", study.id) == 1
    end

    test "--clear-actions drops them as well" do
      study = study()
      populate(study)

      capture_io(fn ->
        Mix.Tasks.Epidemica.ResetStudy.run(["--study", study.id, "--yes", "--clear-actions"])
      end)

      assert count("game_actions", study.id) == 0
    end

    test "keeps everything the study observed" do
      study = study()
      populate(study)

      observations = count("observations", study.id)
      contacts = count("contacts", study.id)
      participants = count("participants", study.id)

      capture_io(fn -> reset(study.id) end)

      # The observation store is the system of record. A replay that lost it would be running
      # against different data, which is the one thing a replay must not do.
      assert count("observations", study.id) == observations
      assert count("contacts", study.id) == contacts
      assert count("participants", study.id) == participants
    end

    test "leaves the study ready to run the same days again" do
      study = study()
      populate(study)

      before = Repo.one(from t in "twin_ticks", select: t.outputs)
      ledger_before = Repo.all(from e in "game_ledger", order_by: e.subject, select: e.closing)

      capture_io(fn -> reset(study.id) end)

      assert {:ok, _} = Twin.run_tick(study.id, 1, runner: stub())
      assert {:ok, _} = Epigame.settle_day(study.id, 1)

      # The seed is derived from {study_id, day}, so an unchanged replay must land in exactly the
      # same place. Anything else would make a replay a re-roll rather than an experiment.
      assert Repo.one(from t in "twin_ticks", select: t.outputs) == before

      assert Repo.all(from e in "game_ledger", order_by: e.subject, select: e.closing) ==
               ledger_before
    end

    test "another study is untouched" do
      study = study()
      populate(study)
      other = study()
      populate(other)

      capture_io(fn -> reset(study.id) end)

      assert count("twin_ticks", other.id) == 1
      assert count("game_ledger", other.id) == 2
    end
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
