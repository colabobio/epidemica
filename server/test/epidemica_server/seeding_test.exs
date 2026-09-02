defmodule EpidemicaServer.SeedingTest do
  @moduledoc """
  Starting the outbreak.

  A study with no index case runs its full length, settles every day, and simulates nothing — and
  on a participant's screen that is indistinguishable from a disease that failed to spread. These
  tests are the difference between a game and seven days of a green screen.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Repo, Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Twin.Agent

  @starts_at ~U[2026-09-07 06:00:00.000000Z]

  defp study(seed, population \\ 6) do
    twin =
      %{
        "engine" => "starsim",
        "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
        "population" => population
      }
      |> then(&if seed, do: Map.put(&1, "seed", seed), else: &1)

    {:ok, study} =
      Studies.create_study_from_bundle(
        "seeded",
        Jason.encode!(%{
          "bundle_version" => "1.0",
          "study_id" => Ecto.UUID.generate(),
          "title" => "Seeded",
          "modules" => %{"proximity" => %{}},
          "schedule" => %{"starts_at" => "2026-09-07T06:00:00Z", "days" => 7},
          "twin" => twin
        })
      )

    study
  end

  defp participants(study, n) do
    for i <- 1..n do
      Repo.insert!(%Participant{
        study_id: study.id,
        subject: "p-000#{i}",
        enrolled_at: DateTime.add(@starts_at, i, :second)
      })
    end
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
             %{
               "index" => a["index"],
               "subject" => a["subject"],
               "virtual" => a["virtual"],
               "state" => a["state"],
               "newly_infected" => false,
               "infected_on_day" => a["infected_on_day"],
               "recovers_on_day" => a["recovers_on_day"],
               "dies_on_day" => a["dies_on_day"]
             }
           end)
       }}
    end
  end

  defp tick(study, day \\ 1), do: Twin.run_tick(study.id, day, runner: stub())

  defp infected(study), do: Enum.filter(Twin.agents(study.id), &(&1.state == "infected"))

  defp seeded_slots(study) do
    Twin.reconcile_roster(study.id, study.protocol["twin"], 1)
    infected(study) |> Enum.map(& &1.slot) |> Enum.sort()
  end

  test "a study that seeds nothing never starts an outbreak" do
    s = study(nil)
    participants(s, 2)

    {:ok, _} = tick(s)

    # The failure this whole module exists to prevent: everything works, and nothing happens.
    assert infected(s) == []
  end

  test "the declared number of agents begin infected" do
    s = study(%{"infections" => 3})
    participants(s, 2)

    {:ok, _} = tick(s)

    assert length(infected(s)) == 3
  end

  test "index cases are infectious on the first day, not from it" do
    s = study(%{"infections" => 1})
    participants(s, 2)

    {:ok, tick} = tick(s, 1)

    # Infected the day before the study opens, so day one has someone to transmit from. Infecting
    # them *on* day one would waste the first day of a seven-day game.
    agent = hd(infected(s))
    assert agent.infected_on_day == 0

    seeded = Enum.find(tick.inputs["agents"], &(&1["state"] == "infected"))
    assert seeded["infected_on_day"] == 0
  end

  test "by default the lottery falls on the simulated population" do
    # Repeated across studies because the choice is derived from the study id: a single study could
    # spare its participants by luck even if the pool were wrong.
    for _ <- 1..5 do
      s = study(%{"infections" => 2}, 7)
      participants(s, 5)

      {:ok, _} = tick(s)

      # A participant infected on day one loses most of the game to a draw they cannot see or
      # influence, and their infection has no contact behind it to explain it.
      assert Enum.all?(infected(s), & &1.virtual)
    end
  end

  test "a study may deliberately make a participant the index case" do
    s = study(%{"infections" => 1, "among" => "participants"})
    participants(s, 3)

    {:ok, _} = tick(s)

    assert [agent] = infected(s)
    refute agent.virtual
    assert agent.subject != nil
  end

  test "who is chosen is derived, not drawn" do
    # Rebuilding the roster from nothing has to reach the same answer, or a replayed history would
    # not match the one participants were shown.
    for _ <- 1..5 do
      s = study(%{"infections" => 2}, 8)
      participants(s, 2)

      first = seeded_slots(s)
      Repo.delete_all(from a in Agent, where: a.study_id == type(^s.id, :binary_id))

      assert seeded_slots(s) == first
    end
  end

  test "reconciling twice before the first tick does not seed twice" do
    s = study(%{"infections" => 2}, 8)
    participants(s, 2)

    # A day-one tick that failed and is retried runs the roster again. Seeding on each attempt
    # would quietly put more cases into the study than the protocol asked for.
    Twin.reconcile_roster(s.id, s.protocol["twin"], 1)
    Twin.reconcile_roster(s.id, s.protocol["twin"], 1)

    assert length(infected(s)) == 2
  end

  test "a retry after more people have joined still seeds only the declared number" do
    s = study(%{"infections" => 2, "among" => "any"}, 12)
    participants(s, 2)

    Twin.reconcile_roster(s.id, s.protocol["twin"], 1)

    # The realistic retry: the day-one tick failed, more of the class enrolled in the meantime, and
    # the roster runs again over a larger pool. Choosing afresh would leave the earlier cases
    # infected and add new ones on top.
    for i <- 3..7 do
      Repo.insert!(%Participant{
        study_id: s.id,
        subject: "late-000#{i}",
        enrolled_at: DateTime.add(@starts_at, 100 + i, :second)
      })
    end

    Twin.reconcile_roster(s.id, s.protocol["twin"], 1)

    assert length(infected(s)) == 2
  end

  test "seeding happens once, not on every day" do
    s = study(%{"infections" => 1})
    participants(s, 2)

    {:ok, _} = tick(s, 1)
    before = infected(s) |> Enum.map(& &1.id) |> Enum.sort()

    {:ok, _} = tick(s, 2)

    # A study that re-seeded daily would inject a fresh case every morning and never burn out.
    assert infected(s) |> Enum.map(& &1.id) |> Enum.sort() == before
  end

  test "asking for more index cases than the pool holds infects the whole pool" do
    s = study(%{"infections" => 99, "among" => "participants"}, 4)
    participants(s, 2)

    {:ok, _} = tick(s)

    assert length(infected(s)) == 2
  end
end
