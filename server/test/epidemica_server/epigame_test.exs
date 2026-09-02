defmodule EpidemicaServer.EpigameTest do
  @moduledoc """
  Settling a day, and publishing it to the participant.

  The rules themselves are covered by the shared vectors. What is tested here is everything the
  vectors cannot see: that a participant is scored on what they were shown rather than what the tick
  revealed, that a settled day is never revised, and that a contact the study could not attest is
  not paid for.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Epigame, ParticipantState, Projections, Repo, Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Ingest.Observation

  @episode_uri "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json"
  @status_uri "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"
  @day_start ~U[2026-09-02 00:00:00.000000Z]

  # -- fixtures ----------------------------------------------------------------------------------

  defp study(opts \\ []) do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Epigame test",
        "modules" => %{"proximity" => %{}},
        "twin" => %{
          "engine" => "starsim",
          "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
          "population" => Keyword.get(opts, :population, 4)
        },
        "rules" => %{
          "engine" => "epigame",
          "pars" => Keyword.get(opts, :pars, %{})
        }
      })

    {:ok, study} = Studies.create_study_from_bundle("epigame", source)
    study
  end

  defp participant(study, subject) do
    Repo.insert!(%Participant{study_id: study.id, subject: subject, enrolled_at: @day_start})
  end

  defp day_window(day) do
    from = DateTime.add(@day_start, (day - 1) * 86_400, :second)
    {from, DateTime.add(from, 86_400, :second)}
  end

  defp sensing(study, subject, day) do
    {from, to} = day_window(day)

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

  defp episode(study, reporter, peer, day, minutes, opts \\ []) do
    {from, _} = day_window(day)
    ended = DateTime.add(from, minutes * 60, :second)

    Repo.insert!(%Observation{
      study_id: study.id,
      subject: reporter,
      device_id: "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
      seq: System.unique_integer([:positive]),
      module: "proximity",
      schema_uri: @episode_uri,
      envelope_version: "1.0",
      observed_at: ended,
      received_at: Keyword.get(opts, :received_at, DateTime.utc_now()),
      envelope: %{},
      payload: %{
        "peer" => peer,
        "started_at" => DateTime.to_iso8601(from),
        "ended_at" => DateTime.to_iso8601(ended),
        "band_seconds" => %{"immediate" => minutes * 60, "close" => 0, "medium" => 0, "far" => 0},
        "band_edges_m" => [1.0, 2.0, 5.0],
        "sample_count" => 10,
        "estimator" => "coarse_distance",
        "estimator_version" => "2.0.0"
      },
      validated: true
    })

    Projections.project_contacts(study.id)
  end

  # An engine stand-in that leaves everyone as they are unless told otherwise.
  defp twin_runner(infect) do
    fn inputs ->
      {:ok,
       %{
         "day" => inputs["day"],
         "engine" => "starsim",
         "engine_version" => "3.6.1",
         "seed" => inputs["seed"],
         "newly_infected" => length(infect),
         "total_cases" => inputs["total_cases_before"] + length(infect),
         "agents" =>
           Enum.map(inputs["agents"], fn a ->
             newly = a["subject"] in infect

             %{
               "index" => a["index"],
               "subject" => a["subject"],
               "virtual" => a["virtual"],
               "state" => if(newly, do: "infected", else: a["state"]),
               "newly_infected" => newly,
               "infected_on_day" => if(newly, do: inputs["day"], else: a["infected_on_day"]),
               "recovers_on_day" => if(newly, do: inputs["day"] + 6, else: a["recovers_on_day"]),
               "dies_on_day" => a["dies_on_day"]
             }
           end)
       }}
    end
  end

  defp tick(study, day, infect \\ []) do
    {:ok, _} =
      Twin.run_tick(study.id, day, anchor: @day_start, runner: twin_runner(infect))
  end

  defp settle(study, day), do: Epigame.settle_day(study.id, day)

  defp lines(study, subject, day) do
    Repo.get_by!(EpidemicaServer.Epigame.LedgerEntry,
      study_id: study.id,
      subject: subject,
      day: day
    ).settlement["lines"]
  end

  # -- eligibility -------------------------------------------------------------------------------

  test "a study with no rules block is never scored" do
    {:ok, plain} =
      Studies.create_study_from_bundle(
        "unscored",
        Jason.encode!(%{
          "bundle_version" => "1.0",
          "study_id" => Ecto.UUID.generate(),
          "title" => "Unscored",
          "modules" => %{"proximity" => %{}}
        })
      )

    assert {:error, :not_a_scored_study} = Epigame.settle_day(plain.id, 1)
  end

  test "a day with no tick cannot be settled" do
    s = study()
    participant(s, "alice-0001")

    # Points derive from published state. Settling ahead of the tick would be scoring a day nobody
    # has been told about yet.
    assert {:error, :no_tick} = settle(s, 1)
  end

  # -- points follow what the participant was shown ------------------------------------------------

  test "a participant infected by today's tick still earns today" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    tick(s, 1, ["alice-0001"])
    {:ok, _} = settle(s, 1)

    # They were shown 'susceptible' all day; the infection is news that arrives with the tick.
    assert [%{"reason" => "healthy", "points" => 2}] = lines(s, "alice-0001", 1)
    assert Epigame.balance(s.id, "alice-0001") == 2
  end

  test "the day after an infection earns nothing" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "alice-0001", 2)

    tick(s, 1, ["alice-0001"])
    {:ok, _} = settle(s, 1)
    tick(s, 2)
    {:ok, _} = settle(s, 2)

    assert [%{"reason" => "infected", "points" => 0}] = lines(s, "alice-0001", 2)
    assert Epigame.balance(s.id, "alice-0001") == 2
  end

  # -- involuntary protection -----------------------------------------------------------------------

  test "a participant who was not sensing accrues nothing and is charged nothing" do
    s = study()
    participant(s, "alice-0001")

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    # Charging would correlate the score with how aggressively their phone kills apps; paying would
    # make going dark the dominant strategy.
    assert [%{"reason" => "not_sensing", "points" => 0}] = lines(s, "alice-0001", 1)
    assert Epigame.balance(s.id, "alice-0001") == 0
  end

  test "going dark is worse than choosing protection, which is worse than playing" do
    s = study()
    for who <- ~w(player-0001 careful-0001 dark-0001), do: participant(s, who)
    sensing(s, "player-0001", 1)
    sensing(s, "careful-0001", 1)

    {from, _} = day_window(1)
    :ok = Epigame.protect(s.id, "careful-0001", from)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    # The ordering that keeps the study alive: if going dark paid as well as playing, nobody would
    # ever be observed.
    assert Epigame.balance(s.id, "player-0001") == 2
    assert Epigame.balance(s.id, "careful-0001") == 1
    assert Epigame.balance(s.id, "dark-0001") == 0
  end

  test "the reason for protection is recorded even though the game treats them alike" do
    s = study()
    participant(s, "chose-0001")
    participant(s, "dark-0001")
    sensing(s, "chose-0001", 1)

    {from, _} = day_window(1)
    :ok = Epigame.protect(s.id, "chose-0001", from)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    {:ok, chose} = ParticipantState.fetch(s.id, "chose-0001")
    {:ok, dark} = ParticipantState.fetch(s.id, "dark-0001")

    assert chose.state["protection_source"] == "chosen"
    assert dark.state["protection_source"] == "not_sensing"
  end

  # -- contacts ------------------------------------------------------------------------------------

  test "a qualifying contact pays both participants" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "bob-0001", 1)
    episode(s, "alice-0001", "bob-0001", 1, 30)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert Epigame.balance(s.id, "alice-0001") == 7
    assert Epigame.balance(s.id, "bob-0001") == 7
  end

  test "a contact with a protected participant pays neither" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "bob-0001", 1)
    episode(s, "alice-0001", "bob-0001", 1, 30)

    {from, _} = day_window(1)
    :ok = Epigame.protect(s.id, "bob-0001", from)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    # Protection removes the reward along with the risk; that is the decision being studied.
    assert Epigame.balance(s.id, "alice-0001") == 2
  end

  test "a pair is not paid twice inside the cooldown" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")

    for day <- 1..2 do
      sensing(s, "alice-0001", day)
      sensing(s, "bob-0001", day)
      episode(s, "alice-0001", "bob-0001", day, 30)
      tick(s, day)
      {:ok, _} = settle(s, day)
    end

    # Day one pays the contact; day two is inside the cooldown and pays only the daily rate.
    assert [%{"reason" => "healthy"}] = lines(s, "alice-0001", 2)
    assert Epigame.balance(s.id, "alice-0001") == 9
  end

  test "a contact with a participant the study could not hear from pays nobody" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    episode(s, "alice-0001", "bob-0001", 1, 30)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    # Bob's phone was in a drawer, which makes him protected, and protection removes the reward for
    # both sides. Paying Alice would credit an encounter only one device could attest to.
    assert Epigame.balance(s.id, "alice-0001") == 2
    assert Epigame.balance(s.id, "bob-0001") == 0
  end

  test "a contact too brief to qualify pays nothing" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "bob-0001", 1)
    episode(s, "alice-0001", "bob-0001", 1, 5)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert Epigame.balance(s.id, "alice-0001") == 2
  end

  test "reconciliation can award a contact neither side saw enough of alone" do
    s = study(pars: %{"contact_min_seconds" => 1200})
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "bob-0001", 1)

    # Each side saw 15 minutes of a longer encounter; neither reaches the 20-minute bar, and the
    # union does. The settlement pays out a contact the participant could not have counted.
    episode(s, "alice-0001", "bob-0001", 1, 15)
    episode(s, "bob-0001", "alice-0001", 1, 21)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert Epigame.balance(s.id, "alice-0001") == 7
  end

  test "a contact whose peer reports late is credited to a later settlement" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")

    for day <- 1..2 do
      sensing(s, "alice-0001", day)
      sensing(s, "bob-0001", day)
    end

    tick(s, 1)
    {:ok, _} = settle(s, 1)
    assert Epigame.balance(s.id, "alice-0001") == 2

    # Only now does the episode arrive, after day one was settled.
    episode(s, "alice-0001", "bob-0001", 1, 30)

    tick(s, 2)
    {:ok, _} = settle(s, 2)

    reasons = lines(s, "alice-0001", 2) |> Enum.map(& &1["reason"])
    assert "carried_over" in reasons

    # Day one is untouched: a participant's settled day never changes under them.
    assert [%{"reason" => "healthy", "points" => 2}] = lines(s, "alice-0001", 1)
    assert Epigame.balance(s.id, "alice-0001") == 9
  end

  # -- immutability and publication ----------------------------------------------------------------

  test "a settled day is never settled twice" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert {:error, :already_settled} = settle(s, 1)
    assert Epigame.balance(s.id, "alice-0001") == 2
  end

  test "the published settlement adds up" do
    s = study()
    participant(s, "alice-0001")
    participant(s, "bob-0001")
    sensing(s, "alice-0001", 1)
    sensing(s, "bob-0001", 1)
    episode(s, "alice-0001", "bob-0001", 1, 30)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    {:ok, doc} = ParticipantState.fetch(s.id, "alice-0001")
    settlement = doc.state["settlement"]

    movement = settlement["lines"] |> Enum.map(& &1["points"]) |> Enum.sum()
    assert settlement["opening"] + movement == settlement["closing"]
    assert settlement["closing"] == doc.state["points"]
  end

  test "the participant is shown the state the tick just produced" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    tick(s, 1, ["alice-0001"])
    {:ok, _} = settle(s, 1)

    {:ok, doc} = ParticipantState.fetch(s.id, "alice-0001")

    # Today's earnings came from yesterday's state, but what they are shown now is current.
    assert doc.state["epi_state"] == "infected"
    assert doc.state["settlement"]["lines"] == [%{"reason" => "healthy", "points" => 2}]
  end

  test "every rule constant comes from the bundle" do
    s = study(pars: %{"healthy_points" => 11, "protection_cost" => 4})
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    {from, _} = day_window(1)
    :ok = Epigame.protect(s.id, "alice-0001", from)

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert Epigame.balance(s.id, "alice-0001") == 7
  end

  # -- the simulation has to know about the choice -------------------------------------------------

  test "a participant who chose protection is protected in the simulation too" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    {from, _} = day_window(1)
    :ok = Epigame.protect(s.id, "alice-0001", from)

    tick(s, 1)

    # Charging for protection that did not protect would be taking a point for nothing.
    agent =
      Repo.get_by!(EpidemicaServer.Twin.Tick, study_id: s.id, day: 1).inputs["agents"]
      |> Enum.find(&(&1["subject"] == "alice-0001"))

    assert agent["protected"] == true
  end

  test "protection released before the day begins does not protect" do
    s = study()
    participant(s, "alice-0001")
    sensing(s, "alice-0001", 1)

    {from, _} = day_window(1)
    earlier = DateTime.add(from, -7200, :second)
    :ok = Epigame.protect(s.id, "alice-0001", earlier)
    :ok = Epigame.release(s.id, "alice-0001", DateTime.add(earlier, 60, :second))

    tick(s, 1)
    {:ok, _} = settle(s, 1)

    assert [%{"reason" => "healthy", "points" => 2}] = lines(s, "alice-0001", 1)
  end

  test "releasing when unprotected is refused rather than silently accepted" do
    s = study()
    participant(s, "alice-0001")

    assert {:error, :not_protected} = Epigame.release(s.id, "alice-0001")
  end
end
