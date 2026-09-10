defmodule EpidemicaServer.Twin.SchedulerTest do
  @moduledoc """
  Which days are due, and when.

  The scheduler's whole job is to not be clever in a way that costs a study a day, or decides one
  before its data has arrived. Each test here pins one way that could go wrong: a day offered before
  its buffer, a day offered twice, a day offered for a study with no twin, one that has not started,
  one that has closed, and — the case worth the most — the final day of a study that has ended,
  which is over but no more finished arriving than any other.
  """

  use EpidemicaServer.DataCase, async: true

  import Ecto.Query

  alias EpidemicaServer.{Ops, Repo, Studies}
  alias EpidemicaServer.Twin.{Scheduler, Tick}

  @starts_at ~U[2026-09-02 00:00:00.000000Z]

  defp bundle(extra) do
    Map.merge(
      %{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Scheduler",
        "modules" => %{"proximity" => %{}},
        "schedule" => %{
          "starts_at" => DateTime.to_iso8601(@starts_at),
          "days" => 7
        }
      },
      extra
    )
  end

  defp study(extra \\ %{}) do
    twin = %{
      "engine" => "starsim",
      "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
      "population" => 4
    }

    source = Jason.encode!(bundle(Map.merge(%{"twin" => twin}, extra)))
    {:ok, study} = Studies.create_study_from_bundle("scheduler study", source)
    study
  end

  defp tick(study, day) do
    period_start = DateTime.add(@starts_at, (day - 1) * 86_400, :second)
    period_end = DateTime.add(period_start, 86_400, :second)

    Repo.insert!(%Tick{
      study_id: study.id,
      day: day,
      inputs: %{},
      outputs: %{},
      period_start: period_start,
      period_end: period_end,
      received_before: period_end,
      seed: 0,
      engine: "starsim",
      engine_version: "3.6.1",
      ran_at: DateTime.utc_now()
    })
  end

  defp tick_jobs do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "EpidemicaServer.Twin.Worker"),
      :count
    )
  end

  describe "which days are due" do
    test "nothing before the study opens" do
      study()

      assert Scheduler.due_ticks(~U[2026-09-01 12:00:00Z]) == []
    end

    test "nothing for a day that is still running" do
      study()

      assert Scheduler.due_ticks(~U[2026-09-02 23:00:00Z]) == []
    end

    test "nothing in the buffer after a day ends" do
      study()

      # Day 1 ends at 2026-09-03 00:00. A tick fired now would freeze the network before the last
      # phones have uploaded, and a settled day is never revisited.
      assert Scheduler.due_ticks(~U[2026-09-03 00:20:00Z]) == []
    end

    test "the day becomes due once its buffer has passed" do
      s = study()

      assert Scheduler.due_ticks(~U[2026-09-03 00:30:00Z]) == [{s.id, 1}]
    end

    test "the buffer follows the study's own sync interval" do
      s = study(%{"sync" => %{"min_interval_seconds" => 3600}})

      # A study whose phones sync hourly has to wait an hour, not the default half.
      assert Scheduler.due_ticks(~U[2026-09-03 00:30:00Z]) == []
      assert Scheduler.due_ticks(~U[2026-09-03 01:00:00Z]) == [{s.id, 1}]
    end

    test "a study with no twin block is never scheduled" do
      {:ok, _} =
        Studies.create_study_from_bundle("collection only", Jason.encode!(bundle(%{})))

      assert Scheduler.due_ticks(~U[2026-09-05 00:00:00Z]) == []
    end

    test "a closed study is never scheduled" do
      s = study()
      s |> Ecto.Changeset.change(status: "closed") |> Repo.update!()

      assert Scheduler.due_ticks(~U[2026-09-05 00:00:00Z]) == []
    end

    test "a day already ticked is not offered again" do
      s = study()
      tick(s, 1)

      assert Scheduler.due_ticks(~U[2026-09-04 00:30:00Z]) == [{s.id, 2}]
    end

    test "a finished study still offers every day it never ran" do
      s = study()

      # Seven days ending 2026-09-09. Refusing here would leave a study nobody ticked in time
      # permanently unsettled.
      assert Scheduler.due_ticks(~U[2026-09-12 00:00:00Z]) == for(d <- 1..7, do: {s.id, d})
    end

    test "the last day of a finished study waits for its buffer like any other" do
      study()

      # Day 7 ends at 2026-09-09 00:00 and the study is over. Over is not the same as finished
      # arriving: ticking here would decide the final day against incomplete uploads, which is
      # exactly the failure the buffer exists to prevent, on the day it matters most.
      assert Scheduler.due_ticks(~U[2026-09-09 00:10:00Z]) |> Enum.map(&elem(&1, 1)) == [
               1,
               2,
               3,
               4,
               5,
               6
             ]
    end
  end

  describe "enqueueing" do
    test "a day is enqueued once, however often the scheduler asks" do
      study()
      at = ~U[2026-09-03 00:30:00Z]

      # The scheduler keeps finding the day due until a tick row exists, so without uniqueness on
      # the worker a study whose tick cannot run would gain a job an hour, for ever.
      assert Scheduler.run(at) == 1
      assert Scheduler.run(at) == 0
      assert tick_jobs() == 1
    end

    test "each due day gets its own job" do
      study()

      Scheduler.run(~U[2026-09-12 00:00:00Z])

      assert tick_jobs() == 7
    end
  end

  describe "operator entry points" do
    test "status separates a day that is behind from one that is not yet due" do
      s = study()
      tick(s, 1)

      out = ExUnit.CaptureIO.capture_io(fn -> assert Ops.status(s.id) == :ok end)

      assert out =~ "ticked:  1 of"
      assert out =~ "behind:  2,"
      assert Ops.status(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "catch_up refuses a study that has not started" do
      # `days_to_catch_up/2` is the same function the scheduler uses, so the two cannot disagree
      # about which days a study has.
      s = study(%{"schedule" => %{"starts_at" => "2099-01-01T00:00:00Z", "days" => 7}})

      assert Ops.catch_up(s.id) == {:error, :not_started}
      assert Ops.catch_up(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end
end
