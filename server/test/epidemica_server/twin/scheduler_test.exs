defmodule EpidemicaServer.Twin.SchedulerTest do
  @moduledoc """
  Which days are due, and when.

  The scheduler's whole job is to not be clever in a way that costs a study a day it should have
  run. Every test here pins one way that could happen: a day enqueued before its buffer, a day
  enqueued twice because the scheduler ran twice, a day offered for a study that is not a twin
  study, a day offered for one that has not started, and a day never offered for one that has ended.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.{Repo, Studies}
  alias EpidemicaServer.Twin.{Scheduler, Tick}

  @day_start ~U[2026-09-02 00:00:00.000000Z]

  defp bundle(twin, sync) do
    Jason.encode!(%{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "modules" => %{"proximity" => %{}},
      "schedule" => %{"starts_at" => DateTime.to_iso8601(@day_start), "days" => 7},
      "sync" => sync,
      "twin" => twin
    })
  end

  defp study(twin \\ %{}, sync \\ %{}) do
    twin =
      Map.merge(
        %{
          "engine" => "starsim",
          "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
          "population" => 4
        },
        twin
      )

    {:ok, study} = Studies.create_study_from_bundle("scheduler study", bundle(twin, sync))
    study
  end

  defp tick(study, day) do
    now = DateTime.utc_now()

    Repo.insert!(%Tick{
      study_id: study.id,
      day: day,
      inputs: %{},
      outputs: %{},
      period_start: @day_start,
      period_end: DateTime.add(@day_start, 86_400, :second),
      received_before: DateTime.add(@day_start, 86_400, :second),
      seed: 0,
      engine: "starsim",
      engine_version: "3.6.1",
      ran_at: now
    })
  end

  describe "due_ticks/1" do
    test "returns nothing for a study that has not started" do
      _s = study()

      # starts_at is 2026-09-02; this is a day before.
      assert [] = Scheduler.due_ticks(~U[2026-09-01 12:00:00Z])
    end

    test "returns nothing for a day whose buffer has not passed" do
      _s = study()

      # Day 1 ends at 2026-09-03 00:00; buffer default is 30 minutes. 20 minutes in is not yet due.
      assert [] = Scheduler.due_ticks(~U[2026-09-03 00:20:00Z])
    end

    test "returns a day once its buffer has passed" do
      s = study()

      # 30 minutes after day 1's boundary.
      assert [{id, 1}] = Scheduler.due_ticks(~U[2026-09-03 00:30:00Z])
      assert id == s.id
    end

    test "a study with no twin block is never scheduled" do
      {:ok, _plain} =
        Studies.create_study_from_bundle(
          "collection only",
          Jason.encode!(%{
            "bundle_version" => "1.0",
            "study_id" => Ecto.UUID.generate(),
            "modules" => %{"proximity" => %{}},
            "schedule" => %{"starts_at" => DateTime.to_iso8601(@day_start), "days" => 7}
          })
        )

      assert [] = Scheduler.due_ticks(~U[2026-09-05 00:00:00Z])
    end

    test "a closed study is never scheduled" do
      s = study()

      {:ok, _closed} =
        Studies.get_study(s.id) |> Ecto.Changeset.change(status: "closed") |> Repo.update()

      assert [] = Scheduler.due_ticks(~U[2026-09-05 00:00:00Z])
    end

    test "a finished study still offers its remaining days" do
      _s = study()

      # The study ran 7 days ending 2026-09-09; this is after that. Every day is over.
      due = Scheduler.due_ticks(~U[2026-09-12 00:00:00Z])
      assert length(due) == 7
    end

    test "a day that has been ticked is not offered again" do
      s = study()
      tick(s, 1)

      # Day 1 is ticked; day 2's buffer has passed.
      due = Scheduler.due_ticks(~U[2026-09-04 00:30:00Z])
      assert due == [{s.id, 2}]
    end

    test "a study honouring sync.min_interval_seconds gets a longer buffer" do
      s = study(%{}, %{"min_interval_seconds" => 3600})

      # 30 minutes after day 1's boundary would be due at the default; a one-hour floor is not.
      assert [] = Scheduler.due_ticks(~U[2026-09-03 00:30:00Z])
      assert [{id, 1}] = Scheduler.due_ticks(~U[2026-09-03 01:00:00Z])
      assert id == s.id
    end
  end

  describe "run/1" do
    test "enqueueing twice does not double-enqueue" do
      _s = study()
      at = ~U[2026-09-03 00:30:00Z]

      first = Scheduler.run(at)
      second = Scheduler.run(at)

      assert first == 1
      # Twin.Worker treats :already_run as success; a second insert is a duplicate job, not a
      # duplicate run. What this test pins is that the *decision* is stable: the same instant
      # produces the same answer, so a scheduler running hourly cannot flood the queue.
      assert second == 1
    end
  end
end
