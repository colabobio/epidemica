defmodule EpidemicaServer.ScheduleTest do
  @moduledoc """
  When a study starts, and when it stops.

  A study's days are the unit everything else is numbered in: a tick, a settlement, the progress a
  participant is shown. If the boundaries move, or if there is no last day, none of those mean what
  they say.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Studies, Twin}
  alias EpidemicaServer.Enrollment.Participant

  @starts_at ~U[2026-09-07 06:00:00.000000Z]

  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp study(schedule) do
    protocol = %{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "title" => "Scheduled",
      "modules" => %{"proximity" => %{}},
      "twin" => %{
        "engine" => "starsim",
        "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
        "population" => 3
      }
    }

    protocol = if schedule, do: Map.put(protocol, "schedule", schedule), else: protocol
    {:ok, study} = Studies.create_study_from_bundle("scheduled", Jason.encode!(protocol))
    study
  end

  defp seven_days, do: study(%{"starts_at" => "2026-09-07T06:00:00Z", "days" => 7})

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

  describe "reading the schedule" do
    test "the start comes from the bundle, not from when the study was registered" do
      s = seven_days()

      # Seeding the same protocol again must not move a boundary participants' days are numbered
      # from; `inserted_at` would do exactly that.
      assert same_instant?(Studies.starts_at(s), @starts_at)
      refute same_instant?(Studies.starts_at(s), s.inserted_at)
    end

    test "a study without a schedule has neither start nor end" do
      s = study(nil)

      assert Studies.starts_at(s) == nil
      assert Studies.scheduled_days(s) == nil
    end
  end

  describe "which day it is" do
    test "the first instant of the study is day one" do
      assert Studies.day_at(seven_days(), @starts_at) == 1
    end

    test "the last instant before the boundary is still day one" do
      assert Studies.day_at(seven_days(), DateTime.add(@starts_at, 86_399, :second)) == 1
    end

    test "the boundary itself is day two" do
      assert Studies.day_at(seven_days(), DateTime.add(@starts_at, 86_400, :second)) == 2
    end

    test "before the study opens there is no day" do
      # Not day zero and not day one: a participant who joined early is waiting, not playing.
      assert Studies.day_at(seven_days(), DateTime.add(@starts_at, -1, :second)) == nil
    end

    test "after the last day there is no day" do
      assert Studies.day_at(seven_days(), DateTime.add(@starts_at, 7 * 86_400, :second)) == nil
    end

    test "the final day is included" do
      last = DateTime.add(@starts_at, 6 * 86_400 + 100, :second)
      assert Studies.day_at(seven_days(), last) == 7
    end
  end

  describe "a study whose day is not a day" do
    defp short_study(seconds) do
      protocol = %{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Short",
        "modules" => %{"proximity" => %{}},
        "schedule" => %{"starts_at" => "2026-09-07T06:00:00Z", "days" => 7},
        "twin" => %{
          "engine" => "starsim",
          "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
          "population" => 3,
          "tick_interval_seconds" => seconds
        }
      }

      {:ok, study} = Studies.create_study_from_bundle("short", Jason.encode!(protocol))
      study
    end

    test "the interval comes from the bundle" do
      assert Studies.tick_interval(short_study(300)) == 300
    end

    test "a study that declares no interval is measured in days" do
      assert Studies.tick_interval(seven_days()) == 86_400
    end

    test "days are counted in the study's own unit" do
      s = short_study(300)

      # The tick period and the current day have to agree, or a scheduler runs a day the simulation
      # is not on. Assuming 86_400 here would report day 1 for the whole run.
      assert Studies.day_at(s, @starts_at) == 1
      assert Studies.day_at(s, DateTime.add(@starts_at, 299, :second)) == 1
      assert Studies.day_at(s, DateTime.add(@starts_at, 300, :second)) == 2
      assert Studies.day_at(s, DateTime.add(@starts_at, 1800, :second)) == 7
    end

    test "the study ends after its own last day, not after seven calendar days" do
      s = short_study(300)

      assert Studies.day_at(s, DateTime.add(@starts_at, 7 * 300, :second)) == nil
      refute Studies.running?(s, DateTime.add(@starts_at, 7 * 300, :second))
      assert Studies.running?(s, DateTime.add(@starts_at, 600, :second))
    end

    test "the tick period matches the declared interval" do
      s = short_study(300)
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      {:ok, tick} = Twin.run_tick(s.id, 2, allow_incomplete: true, runner: stub())

      assert same_instant?(tick.period_start, DateTime.add(@starts_at, 300, :second))
      assert same_instant?(tick.period_end, DateTime.add(@starts_at, 600, :second))
    end
  end

  describe "catching up" do
    test "runs from day one to the day in progress" do
      s = study(%{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7})
      at = ~U[2020-01-03 12:00:00.000000Z]

      assert {:ok, [1, 2, 3]} = Studies.days_to_catch_up(s, at)
    end

    test "a study that has ended can still be caught up" do
      s = study(%{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7})

      # Every day is over and therefore decidable, and `--day <n>` would run each of them. Refusing
      # here would leave a study nobody ticked in time permanently unsettled.
      assert {:ok, [1, 2, 3, 4, 5, 6, 7]} = Studies.days_to_catch_up(s, ~U[2021-06-01 00:00:00Z])
    end

    test "the last day is included on the day it ends" do
      s = study(%{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7})
      last = ~U[2020-01-07 23:59:59.000000Z]

      assert {:ok, days} = Studies.days_to_catch_up(s, last)
      assert List.last(days) == 7
    end

    test "a study that has not started has nothing to catch up" do
      s = seven_days()

      assert {:error, :not_started} = Studies.days_to_catch_up(s, @starts_at |> DateTime.add(-1))
    end

    test "a study with no schedule cannot be caught up" do
      # There is no day one to count from, so the caller has to name the day it wants.
      assert {:error, :no_schedule} = Studies.days_to_catch_up(study(nil))
    end

    test "an open-ended study counts on past its declared length, because it has none" do
      s = study(%{"starts_at" => "2020-01-01T00:00:00Z", "days" => nil})

      assert {:ok, days} = Studies.days_to_catch_up(s, ~U[2020-01-05 00:00:00Z])
      assert days == [1, 2, 3, 4, 5]
    end

    test "a short-tick study counts in its own unit" do
      s = short_study(300)

      assert {:ok, [1, 2, 3]} =
               Studies.days_to_catch_up(s, DateTime.add(@starts_at, 700, :second))
    end
  end

  describe "ticking within the schedule" do
    test "day one covers the declared start" do
      s = seven_days()
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      {:ok, tick} = Twin.run_tick(s.id, 1, allow_incomplete: true, runner: stub())

      assert same_instant?(tick.period_start, @starts_at)
      assert same_instant?(tick.period_end, DateTime.add(@starts_at, 86_400, :second))
    end

    test "a day that has not finished yet is refused" do
      s = seven_days()
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      # The schedule starts in the future, so day 1 has not happened. Ticking it would settle a day
      # on a network that does not exist yet, and a tick is immutable — the wrong answer would be
      # permanent.
      assert {:error, :day_not_finished} = Twin.run_tick(s.id, 1, runner: stub())
    end

    test "a demonstration can tick an unfinished day on purpose" do
      s = seven_days()
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      assert {:ok, _} = Twin.run_tick(s.id, 1, allow_incomplete: true, runner: stub())
    end

    test "a day that has elapsed runs without asking" do
      s = study(%{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7})
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      assert {:ok, _} = Twin.run_tick(s.id, 1, runner: stub())
    end

    test "a day past the end of the study is refused" do
      s = seven_days()
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      # A game that keeps ticking after the final score has been shown would revise a result
      # participants had already been given.
      assert {:error, :after_study_end} =
               Twin.run_tick(s.id, 8, allow_incomplete: true, runner: stub())
    end

    test "day zero is refused" do
      s = seven_days()

      assert {:error, :before_study_start} =
               Twin.run_tick(s.id, 0, allow_incomplete: true, runner: stub())
    end

    test "the last day still runs" do
      s = seven_days()
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      assert {:ok, _} = Twin.run_tick(s.id, 7, allow_incomplete: true, runner: stub())
    end

    test "a study with no schedule still ticks, anchored on registration" do
      s = study(nil)
      Repo.insert!(%Participant{study_id: s.id, subject: "alice-0001", enrolled_at: @starts_at})

      # Collection-only studies have no days to number, so falling back is the honest behaviour
      # rather than refusing to run at all.
      assert {:ok, tick} = Twin.run_tick(s.id, 1, allow_incomplete: true, runner: stub())
      assert same_instant?(tick.period_start, s.inserted_at)
    end
  end
end
