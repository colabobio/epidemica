defmodule EpidemicaServer.Twin.Scheduler do
  @moduledoc """
  Finds study-days that are due and have not been run, and enqueues them.

  Runs on a schedule owned by `Oban.Plugins.Cron` rather than on a timer of its own, so an hour of
  downtime is a delayed tick rather than a lost one: the next run asks the same question again and
  gets the same answer. This module is only the *decision* of what is due. Running it is
  `Twin.Worker`'s job, and that worker is idempotent, so being asked twice costs nothing.

  What this deliberately does not do is decide a day the instant it ends. A tick freezes its network
  at `received_before`, and a phone syncs on its own schedule, so a tick that fires on the boundary
  settles the day before its last uploads have landed — and those uploads then have nowhere to go,
  because the day they belong to is already decided and a settled day is never revisited. The lag is
  `sync.min_interval_seconds` where the study states one, and 30 minutes where it does not.

  Runs in its own queue. Sharing `twin` would put the hourly decision behind whatever ticks are
  already queued, so a study catching up on a week of days would stop noticing new ones.
  """

  use Oban.Worker, queue: :scheduler, max_attempts: 1

  import Ecto.Query

  alias EpidemicaServer.{Repo, Studies}
  alias EpidemicaServer.Studies.Study
  alias EpidemicaServer.Twin.{Tick, Worker}

  require Logger

  # Long enough that a phone on the default sync interval gets its last observations in; short
  # enough that nobody waits all morning for yesterday's score.
  @default_buffer_seconds 30 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      0 -> :ok
      n -> Logger.info("twin scheduler enqueued #{n} tick(s)")
    end

    :ok
  end

  @doc """
  Every `{study_id, day}` that is due now and has no tick yet, across every open study.

  Pairs rather than jobs, so a test can assert what should run without asserting anything about
  Oban.
  """
  def due_ticks(at \\ DateTime.utc_now()) do
    Repo.all(from s in Study, where: s.status == "open")
    |> Enum.flat_map(&due_for(&1, at))
  end

  @doc """
  Enqueue every due day. Returns how many jobs were actually inserted.

  A day already queued is not counted, because it was not enqueued: `Twin.Worker` is unique across
  the live states, so the hourly run finds the same day due and inserts nothing.
  """
  def run(at \\ DateTime.utc_now()) do
    due_ticks(at)
    |> Enum.count(fn {study_id, day} ->
      match?({:ok, %Oban.Job{conflict?: false}}, Worker.enqueue(study_id, day))
    end)
  end

  # A study with no twin block is never simulated, and one that has not started has no days yet.
  # Both are ordinary answers rather than errors: `days_to_catch_up/2` already distinguishes them,
  # and reusing it keeps one definition of which days a study has.
  defp due_for(%Study{} = study, at) do
    with {:ok, twin} <- twin_block(study),
         {:ok, days} <- Studies.days_to_catch_up(study, at) do
      days
      |> Enum.filter(&decidable?(study, twin, &1, at))
      |> Enum.reject(&ticked?(study.id, &1))
      |> Enum.map(&{study.id, &1})
    else
      _ -> []
    end
  end

  defp twin_block(%Study{protocol: %{"twin" => twin}}) when is_map(twin), do: {:ok, twin}
  defp twin_block(_study), do: :error

  # Over, and far enough past over that anything still in flight has landed. Applies to a finished
  # study's last day exactly as it does mid-run: ending is not the same as having been reported.
  defp decidable?(study, _twin, day, at) do
    period_end =
      Studies.starts_at(study)
      |> DateTime.add(day * Studies.tick_interval(study), :second)
      |> DateTime.add(buffer_seconds(study), :second)

    DateTime.compare(period_end, at) != :gt
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
