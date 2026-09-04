defmodule EpidemicaServer.TwinTest do
  @moduledoc """
  The twin runtime: a day of the epidemic, decided once.

  A tick is the only thing in the platform whose output is fiction — a simulated infection that a
  real person is told about. Every test here guards a property that keeps that fiction accountable:
  that it can be reproduced from the record, that it is never silently revised, and that a
  participant is never told something the study cannot afterwards explain.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Repo, Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Ingest.Observation
  alias EpidemicaServer.Twin.{Agent, Tick}

  @status_uri "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"
  @day_start ~U[2026-09-02 00:00:00.000000Z]

  # -- fixtures ---------------------------------------------------------------------------------

  defp bundle(twin) do
    Jason.encode!(%{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "modules" => %{"proximity" => %{}},
      "twin" => twin
    })
  end

  defp study(twin \\ %{}) do
    twin =
      Map.merge(
        %{
          "engine" => "starsim",
          "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
          "population" => 4
        },
        twin
      )

    {:ok, study} = Studies.create_study_from_bundle("twin study", bundle(twin))
    study
  end

  defp participant(study, subject, enrolled_at \\ @day_start) do
    Repo.insert!(%Participant{
      study_id: study.id,
      subject: subject,
      enrolled_at: enrolled_at
    })
  end

  # A device that reported itself sensing for the whole window; without this a participant counts
  # as unobserved and is treated as protected.
  defp sensing(study, subject, from \\ @day_start, to \\ nil) do
    to = to || DateTime.add(from, 86_400, :second)

    Repo.insert!(%Observation{
      study_id: study.id,
      subject: subject,
      device_id: "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: @status_uri,
      envelope_version: "1.0",
      observed_at: to,
      received_at: DateTime.utc_now(),
      envelope: %{},
      payload: %{
        "state" => "sensing",
        "window_start" => DateTime.to_iso8601(from),
        "window_end" => DateTime.to_iso8601(to)
      },
      validated: true
    })
  end

  # An engine stand-in: returns each agent unchanged unless told to infect particular indices.
  defp stub(opts \\ []) do
    infect = Keyword.get(opts, :infect, [])
    reply = Keyword.get(opts, :reply)

    fn inputs ->
      reply ||
        {:ok,
         %{
           "day" => inputs["day"],
           "engine" => "starsim",
           "engine_version" => Keyword.get(opts, :version, "3.6.1"),
           "seed" => inputs["seed"],
           "newly_infected" => length(infect),
           "total_cases" => inputs["total_cases_before"] + length(infect),
           "agents" =>
             Enum.map(inputs["agents"], fn a ->
               newly = a["index"] in infect

               %{
                 "index" => a["index"],
                 "subject" => a["subject"],
                 "virtual" => a["virtual"],
                 "state" => if(newly, do: "infected", else: a["state"]),
                 "newly_infected" => newly,
                 "infected_on_day" => if(newly, do: inputs["day"], else: a["infected_on_day"]),
                 "recovers_on_day" =>
                   if(newly, do: inputs["day"] + 6, else: a["recovers_on_day"]),
                 "dies_on_day" => a["dies_on_day"]
               }
             end)
         }}
    end
  end

  defp run(study, day \\ 1, opts \\ []) do
    Twin.run_tick(
      study.id,
      day,
      Keyword.merge([anchor: @day_start, allow_incomplete: true, runner: stub()], opts)
    )
  end

  # -- which studies are simulated at all -------------------------------------------------------

  describe "eligibility" do
    test "a study with no twin block is never simulated" do
      {:ok, plain} =
        Studies.create_study_from_bundle(
          "collection only",
          Jason.encode!(%{
            "bundle_version" => "1.0",
            "study_id" => Ecto.UUID.generate(),
            "modules" => %{"proximity" => %{}}
          })
        )

      # A study that only collects must not quietly acquire a model, and its participants must
      # never be handed simulated state they did not consent to.
      assert {:error, :not_a_twin_study} =
               Twin.run_tick(plain.id, 1, allow_incomplete: true, runner: stub())
    end

    test "an unknown study is refused rather than created" do
      assert {:error, :not_found} =
               Twin.run_tick(Ecto.UUID.generate(), 1, allow_incomplete: true, runner: stub())
    end
  end

  # -- the population ---------------------------------------------------------------------------

  describe "population" do
    test "virtual participants complete the population to the protocol's size" do
      s = study(%{"population" => 5})
      participant(s, "alice-0001")
      participant(s, "bob-0001")

      {:ok, _} = run(s)

      agents = Twin.agents(s.id)
      assert length(agents) == 5
      assert Enum.count(agents, & &1.virtual) == 3
      assert Enum.count(agents, &(not &1.virtual)) == 2
    end

    test "real participants take slots in enrolment order" do
      s = study()
      participant(s, "second-0001", DateTime.add(@day_start, 60, :second))
      participant(s, "first-0001", @day_start)

      {:ok, _} = run(s)

      real = Twin.agents(s.id) |> Enum.reject(& &1.virtual) |> Enum.sort_by(& &1.slot)
      assert Enum.map(real, & &1.subject) == ["first-0001", "second-0001"]
    end

    test "a participant joining mid-study gets a slot nobody has held" do
      s = study(%{"population" => 3})
      participant(s, "alice-0001")
      {:ok, _} = run(s, 1)

      used_slots = Twin.agents(s.id) |> Enum.map(& &1.slot) |> MapSet.new()

      participant(s, "bob-0001", DateTime.add(@day_start, 86_400, :second))
      {:ok, _} = run(s, 2)

      bob = Repo.get_by!(Agent, study_id: s.id, subject: "bob-0001")

      # Reusing a retired virtual agent's slot would hand a real participant a simulated person's
      # infection history — including, quite possibly, an infection.
      refute MapSet.member?(used_slots, bob.slot)
      assert bob.state == "susceptible"
    end

    test "the population stays at the protocol's size as people join" do
      s = study(%{"population" => 3})
      participant(s, "alice-0001")
      {:ok, _} = run(s, 1)

      participant(s, "bob-0001", DateTime.add(@day_start, 86_400, :second))
      {:ok, _} = run(s, 2)

      agents = Twin.agents(s.id)
      assert Enum.count(agents, & &1.active) == 3

      # The retired agent is kept, not deleted: it was part of days that have already been decided.
      assert Enum.count(agents, &(not &1.active)) == 1
    end

    test "successive joiners never land on a retired agent's slot" do
      s = study(%{"population" => 3})
      participant(s, "alice-0001")
      {:ok, _} = run(s, 1)

      participant(s, "bob-0001", DateTime.add(@day_start, 86_400, :second))
      {:ok, _} = run(s, 2)

      participant(s, "carol-0001", DateTime.add(@day_start, 172_800, :second))
      {:ok, _} = run(s, 3)

      agents = Twin.agents(s.id)
      slots = Enum.map(agents, & &1.slot)

      # Retired agents keep their rows and their slots. A joiner reusing one would inherit a
      # simulated person's history, and the day it happened would no longer mean what it said.
      assert slots == Enum.uniq(slots)
      assert Enum.count(agents, &(not &1.virtual)) == 3
      assert Enum.count(agents, & &1.active) == 3
    end

    test "enrolment beyond the protocol's population is not truncated" do
      s = study(%{"population" => 2})
      for i <- 1..4, do: participant(s, "p-000#{i}", DateTime.add(@day_start, i, :second))

      {:ok, _} = run(s)

      agents = Twin.agents(s.id)
      # Losing a real participant to a population cap would mean a consenting person contributing
      # data and getting nothing back.
      assert Enum.count(agents, &(not &1.virtual)) == 4
      assert Enum.count(agents, & &1.virtual) == 0
    end

    test "a withdrawn participant is not enrolled into the population" do
      s = study(%{"population" => 2})
      participant(s, "alice-0001")

      Repo.insert!(%Participant{
        study_id: s.id,
        subject: "gone-0001",
        enrolled_at: @day_start,
        withdrawn_at: DateTime.utc_now()
      })

      {:ok, _} = run(s)

      subjects = Twin.agents(s.id) |> Enum.map(& &1.subject) |> Enum.reject(&is_nil/1)
      assert subjects == ["alice-0001"]
    end
  end

  # -- immutability -----------------------------------------------------------------------------

  describe "immutability" do
    test "a day that has been decided is never decided again" do
      s = study()
      participant(s, "alice-0001")
      {:ok, _} = run(s, 1, runner: stub(infect: [0]))

      # The second call has a runner that would infect nobody. If the tick were recomputed, the
      # participant would watch their infection disappear.
      assert {:error, :already_run} = run(s, 1, runner: stub())

      assert Repo.get_by!(Agent, study_id: s.id, subject: "alice-0001").state == "infected"
      assert Repo.aggregate(from(t in Tick, where: t.study_id == ^s.id), :count) == 1
    end

    test "days are independent, so a later day can still run" do
      s = study()
      participant(s, "alice-0001")

      {:ok, _} = run(s, 1)
      assert {:ok, _} = run(s, 2)
    end
  end

  # -- failure ----------------------------------------------------------------------------------

  describe "failure" do
    test "a failed tick leaves no trace and can be retried" do
      s = study()
      participant(s, "alice-0001")

      assert {:error, :boom} = run(s, 1, runner: stub(reply: {:error, :boom}))

      assert Repo.aggregate(from(t in Tick, where: t.study_id == ^s.id), :count) == 0
      assert Enum.all?(Twin.agents(s.id), &(&1.state == "susceptible"))

      # Retrying is the whole point: a transient engine failure must not cost the study a day.
      assert {:ok, _} = run(s, 1, runner: stub(infect: [0]))
      assert Repo.get_by!(Agent, study_id: s.id, subject: "alice-0001").state == "infected"
    end
  end

  # -- the record -------------------------------------------------------------------------------

  describe "the record" do
    test "inputs, seed and outputs are all stored" do
      s = study()
      participant(s, "alice-0001")

      {:ok, tick} = run(s)

      assert tick.seed == tick.inputs["seed"]
      assert tick.inputs["agents"] != []
      assert tick.outputs["agents"] != []
      assert tick.period_start == @day_start
      assert tick.received_before
    end

    test "the engine version is recorded on every tick" do
      s = study()
      participant(s, "alice-0001")

      {:ok, tick} = run(s, 1, runner: stub(version: "3.7.0"))

      # A Starsim upgrade mid-study has to be visible in the data rather than inferred from a
      # deployment log.
      assert tick.engine == "starsim"
      assert tick.engine_version == "3.7.0"
    end

    test "the seed depends on the study and the day, not on chance" do
      s = study()
      participant(s, "alice-0001")

      {:ok, one} = run(s, 1)
      {:ok, two} = run(s, 2)

      assert one.seed != two.seed
      # Derived rather than drawn, so a tick stays verifiable even if only the day is known.
      assert {:ok, ^one} = {:ok, Repo.get_by!(Tick, study_id: s.id, day: 1)}
    end

    test "cumulative cases carry from the previous day" do
      s = study()
      participant(s, "alice-0001")

      {:ok, _} = run(s, 1, runner: stub(infect: [0]))
      {:ok, second} = run(s, 2, runner: stub(infect: [1]))

      assert second.inputs["total_cases_before"] == 1
      assert second.outputs["total_cases"] == 2
    end

    test "a stored tick can be replayed and checked against its record" do
      s = study()
      participant(s, "alice-0001")
      {:ok, _} = run(s, 1, runner: stub(infect: [0]))

      assert :ok = Twin.verify_tick(s.id, 1, runner: stub(infect: [0]))

      # An engine that no longer reproduces a stored day is the signal the whole record exists to
      # give; it must not pass quietly.
      assert {:error, {:mismatch, _}} = Twin.verify_tick(s.id, 1, runner: stub())
    end
  end

  # -- protection -------------------------------------------------------------------------------

  describe "protection" do
    test "a participant whose device was not sensing is treated as protected" do
      s = study()
      participant(s, "alice-0001")

      {:ok, tick} = run(s)

      # A phone in a drawer reports nothing. Reading that as "met nobody" would let the model
      # invent an absence of exposure and understate transmission. Protected outright rather than
      # proportionally: no part of the day can be attested.
      alice = Enum.find(tick.inputs["agents"], &(&1["subject"] == "alice-0001"))
      assert alice["protection"] == 1.0
    end

    test "a participant who was sensing is exposed normally" do
      s = study()
      participant(s, "alice-0001")
      sensing(s, "alice-0001")

      {:ok, tick} = run(s)

      alice = Enum.find(tick.inputs["agents"], &(&1["subject"] == "alice-0001"))
      assert alice["protection"] == 0.0
    end

    test "virtual participants are never protected by missing coverage" do
      s = study(%{"population" => 3})
      participant(s, "alice-0001")

      {:ok, tick} = run(s)

      virtual = Enum.filter(tick.inputs["agents"], & &1["virtual"])
      assert virtual != []
      assert Enum.all?(virtual, &(&1["protection"] == 0.0))
    end
  end

  # -- state continuity -------------------------------------------------------------------------

  describe "state continuity" do
    test "an agent's state and clocks carry into the next day" do
      s = study()
      participant(s, "alice-0001")

      {:ok, _} = run(s, 1, runner: stub(infect: [0]))
      {:ok, second} = run(s, 2)

      alice = Enum.find(second.inputs["agents"], &(&1["subject"] == "alice-0001"))
      assert alice["state"] == "infected"
      assert alice["infected_on_day"] == 1
      assert alice["recovers_on_day"] == 7
    end
  end
end
