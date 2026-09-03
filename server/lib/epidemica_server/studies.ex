defmodule EpidemicaServer.Studies do
  @moduledoc "Studies, their protocol bundles, and the codes participants join with."

  import Ecto.Query

  alias EpidemicaServer.Repo
  alias EpidemicaServer.Studies.{JoinCode, Study}

  @default_interval 86_400

  def create_study(attrs) do
    %Study{} |> Study.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Register a study from the exact bytes of an authored bundle.

  The hash is derived here rather than supplied, so a study cannot be created whose stated hash
  describes something other than what it will serve.
  """
  def create_study_from_bundle(name, source) when is_binary(source) do
    with {:ok, decoded} <- Jason.decode(source) do
      create_study(%{
        name: name,
        protocol_source: source,
        protocol: decoded,
        protocol_hash: Study.hash_of(source)
      })
    end
  end

  @doc "The bytes to serve for a study, byte-identical to what was registered."
  def fetch_protocol_source(id) do
    case Repo.one(from s in Study, where: s.id == ^id, select: s.protocol_source) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def add_join_code(%Study{} = study, code, arm \\ nil) do
    %JoinCode{}
    |> JoinCode.changeset(%{study_id: study.id, code: code, arm: arm})
    |> Repo.insert()
  end

  def get_study(id), do: Repo.get(Study, id)

  @doc """
  When day 1 of a study begins, or nil for a study that declares no schedule.

  Read from the bundle rather than from when the study was registered, so that seeding the same
  protocol twice cannot move the boundaries a participant's days are numbered from.
  """
  def starts_at(%Study{protocol: %{"schedule" => %{"starts_at" => starts_at}}}) do
    case DateTime.from_iso8601(starts_at) do
      {:ok, instant, _offset} -> instant
      {:error, _} -> nil
    end
  end

  def starts_at(_study), do: nil

  @doc "How many days a study runs, or nil for open-ended collection."
  def scheduled_days(%Study{protocol: %{"schedule" => %{"days" => days}}}) when is_integer(days),
    do: days

  def scheduled_days(_study), do: nil

  @doc """
  How long one study-day lasts, in seconds.

  Every caller that divides time into days has to agree with `Twin.period/4`, or a study with a
  short tick computes one day here and simulates a different one there. Defined once so there is
  only one default to get wrong.
  """
  def tick_interval(%Study{protocol: %{"twin" => %{"tick_interval_seconds" => seconds}}})
      when is_integer(seconds) and seconds > 0,
      do: seconds

  def tick_interval(_study), do: @default_interval

  @doc "Whether `at` falls inside the study's run. Always true for a study that declares no schedule."
  def running?(%Study{} = study, at \\ DateTime.utc_now()) do
    starts_at(study) == nil or day_at(study, at) != nil
  end

  @doc """
  Which study-day `at` falls in: 1 on the first day, `nil` before the study opens or after it ends.

  The caller that schedules ticks needs this to be a total function over time, because "the study
  has not started" and "the study is over" are both ordinary states rather than errors.

  `interval` defaults to the study's own, so a short-tick study is not silently measured in days.
  """
  def day_at(%Study{} = study, at \\ DateTime.utc_now(), interval \\ nil) do
    interval = interval || tick_interval(study)

    with start when start != nil <- starts_at(study),
         elapsed when elapsed >= 0 <- DateTime.diff(at, start, :second) do
      day = div(elapsed, interval) + 1
      days = scheduled_days(study)

      if days == nil or day <= days, do: day, else: nil
    else
      _ -> nil
    end
  end

  @doc """
  Look up a join code, case-insensitively.

  Codes get read off posters and out of text messages, so requiring exact capitalisation would fail
  participants for no reason.
  """
  def fetch_join_code(code) when is_binary(code) do
    query =
      from j in JoinCode,
        where: fragment("lower(?)", j.code) == ^String.downcase(code),
        preload: [:study]

    case Repo.one(query) do
      nil -> {:error, :no_such_study}
      join_code -> {:ok, join_code}
    end
  end

  def fetch_join_code(_), do: {:error, :no_such_study}
end
