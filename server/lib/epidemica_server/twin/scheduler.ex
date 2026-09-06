defmodule EpidemicaServer.Twin.Scheduler do
  @moduledoc """
  Finds twin study-days that are due and have not been run, and enqueues them.

  Runs on a schedule owned by `Oban.Plugins.Cron`, not on a timer of its own: a day whose tick never
  ran because the scheduler process happened to be down for an hour is recovered by the next cron
  run, not lost. This module itself is the *decision* of what is due; the actual running is
  `Twin.Worker`'s job, which is idempotent, so a day enqueued twice costs one wasted insert, not a
  re-run.

  A day is enqueued as soon as it is over. Nothing waits for the *next* scheduler run to know it
  has ended: `Studies.day_at/3` is a total function over time, so "the study has not started" and
  "the study is over" are both ordinary answers rather than errors.

  What this deliberately does not do: decide a day at the instant it ends. A tick freezes its
  network at `received_before`, and a phone syncs on its own schedule, so a tick that fires the
  moment a day ends settles it before the last uploads land. The lag between a day ending and its
  tick being due is derived from `sync.min_interval_seconds` when the study declares one, and from a
  fixed default when it does not — see `buffer_seconds/1`.
  """

  use Oban.Worker, queue: :twin, max_attempts: 1

  import Ecto.Query

  alias EpidemicaServer.{Repo, Studies}
  alias EpidemicaServer.Studies.Study
  alias EpidemicaServer.Twin.Tick

  require Logger

  # How long after a day ends before its tick is due, when the study says nothing about it. Long
  # enough that a phone on a default 15-minute sync interval has time to get its last observations
  # in; short enough that a participant is not waiting all morning for yesterday's score.
  @default_buffer_seconds 30 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    enqueued = run()

    if enqueued > 0 do
      Logger.info("twin scheduler enqueued #{enqueued} tick(s)")
    end

    :ok
  end

  @doc """
  Every study-day that is due now and has no tick yet, for every open study that has a twin block.

  Returns `{study_id, day}` pairs rather than jobs so a test can assert what *should* run without
  asserting anything about Oban.
  """
  def due_ticks(at \\ DateTime.utc_now()) do
    Repo.all(from s in Study, where: s.status == "open")
    |> Enum.flat_map(fn study -> due_for(study, at) end)
  end

  @doc """
  Enqueue every due day. Returns how many jobs were enqueued.

  Idempotent by construction: `Twin.Worker` treats `already_run` as success, so a day enqueued
  twice because the scheduler ran twice while the first job was still queued costs one insert, not
  a re-run.
  """
  def run(at \\ DateTime.utc_now()) do
    due = due_ticks(at)

    for {study_id, day} <- due do
      EpidemicaServer.Twin.Worker.enqueue(study_id, day)
    end

    length(due)
  end

  defp due_for(%Study{} = study, at) do
    days = Studies.scheduled_days(study)
    current = Studies.day_at(study, at)

    cond do
      # Not a twin study at all: no twin block, so nothing to decide. A collection-only study
      # asking this question is a caller error worth saying no to loudly, not silently defaulting.
      twin_block(study) == :error ->
        []

      # No schedule, and a twin that wants one: run forever, one day per tick interval, starting
      # from the study's own declared start. `starts_at` is still required even though `days` is
      # not — a study with no anchor has no first day to number from.
      days == nil and Studies.starts_at(study) != nil ->
        open_ended_days(study, at)

      # No schedule and no start: a study that collects only, or a bundle missing its anchor.
      days == nil ->
        []

      # Not started yet: day_at is nil because it is before the study opens, not because it is over.
      current == nil and Studies.starts_at(study) != nil and
          DateTime.compare(at, Studies.starts_at(study)) == :lt ->
        []

      # Ended: every day is over and decidable. `day_at` returns nil there by design; a finished
      # study is not a study with nothing left to do.
      current == nil ->
        all_days(study, days)

      # Mid-run: days up to the current one, minus any whose buffer has not yet passed.
      true ->
        decidable = decidable_days(study, current, at)

        decidable
        |> Enum.reject(fn day -> ticked?(study.id, day) end)
        |> Enum.map(fn day -> {study.id, day} end)
    end
  end

  # A study with no twin block is never simulated. Refusing here rather than defaulting keeps a
  # collection-only study from quietly acquiring a model nobody asked for.
  defp twin_block(%Study{protocol: %{"twin" => twin}}) when is_map(twin), do: {:ok, twin}
  defp twin_block(_study), do: :error

  # Days of an open-ended study that are due now: every day from 1 up to the one that ends at the
  # next tick interval boundary, minus any already ticked, with the same buffer as a finite study.
  defp open_ended_days(study, at) do
    starts_at = Studies.starts_at(study)
    interval = Studies.tick_interval(study)
    buffer = buffer_seconds(study)

    # Which tick-interval boundary has passed, counting from the study's start. Zero before the
    # first full interval has elapsed, so a study that started ten minutes ago has no day due yet.
    current = div(DateTime.diff(at, starts_at, :second), interval)

    1..current
    |> Enum.filter(fn day ->
      period_end = DateTime.add(starts_at, day * interval, :second)
      DateTime.compare(DateTime.add(period_end, buffer, :second), at) != :gt
    end)
    |> Enum.reject(fn day -> ticked?(study.id, day) end)
    |> Enum.map(fn day -> {study.id, day} end)
  end

  # Every day of a study that has ended. Nothing to filter by buffer: every one of them is over.
  defp all_days(study, days) do
    1..days
    |> Enum.reject(fn day -> ticked?(study.id, day) end)
    |> Enum.map(fn day -> {study.id, day} end)
  end

  # Days that are not merely over but finished settling: period end plus buffer, in the past.
  defp decidable_days(study, current_day, at) do
    starts_at = Studies.starts_at(study)
    interval = Studies.tick_interval(study)
    buffer = buffer_seconds(study)

    1..current_day
    |> Enum.filter(fn day ->
      period_end = DateTime.add(starts_at, day * interval, :second)
      DateTime.compare(DateTime.add(period_end, buffer, :second), at) != :gt
    end)
  end

  defp ticked?(study_id, day) do
    Repo.exists?(
      from t in Tick, where: t.study_id == type(^study_id, :binary_id) and t.day == ^day
    )
  end

  defp buffer_seconds(%Study{protocol: %{"sync" => %{"min_interval_seconds" => seconds}}})
       when is_integer(seconds) and seconds > 0,
       do: seconds

  defp buffer_seconds(_study), do: @default_buffer_seconds
end
