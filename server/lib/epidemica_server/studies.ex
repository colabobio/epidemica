defmodule EpidemicaServer.Studies do
  @moduledoc "Studies, their protocol bundles, and the codes participants join with."

  import Ecto.Query

  alias EpidemicaServer.Contracts
  alias EpidemicaServer.Repo
  alias EpidemicaServer.Studies.{JoinCode, Study}

  @default_interval 86_400
  @default_coverage_threshold 0.5
  @default_health_interval 3600

  def create_study(attrs) do
    %Study{} |> Study.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Register a study from the exact bytes of an authored bundle.

  The hash is derived here rather than supplied, so a study cannot be created whose stated hash
  describes something other than what it will serve.

  The bundle is checked against its contract first. Registration is the last moment anyone is
  watching: the schema is closed at the top level, so a mistyped key is not a validation error at
  run time but a setting that silently keeps its default for the length of the study.

  Returns `{:error, {:invalid_bundle, error}}`, `{:error, {:coverage_not_reported, seconds}}` or
  `{:error, {:health_interval_too_long, interval, maximum}}` for a bundle that would run but could
  never observe anybody.
  """
  def create_study_from_bundle(name, source) when is_binary(source) do
    with {:ok, decoded} <- Jason.decode(source),
         :ok <- validate_bundle(decoded) do
      create_study(%{
        name: name,
        protocol_source: source,
        protocol: decoded,
        protocol_hash: Study.hash_of(source)
      })
    end
  end

  @doc """
  Check an authored bundle against its contract, and against what the twin needs to run.

  The cross-field checks exist because the schema cannot express them and their failure mode is
  silent: a study whose devices cannot report enough coverage does not error, it runs to completion
  with every participant treated as protected and no transmission at all, which on screen is
  indistinguishable from a disease that failed to spread.
  """
  def validate_bundle(decoded) when is_map(decoded) do
    with :ok <- schema(decoded),
         :ok <- arms_distinct(decoded) do
      coverage_reportable(decoded)
    end
  end

  defp schema(decoded) do
    case Contracts.validate_bundle(decoded) do
      :ok -> :ok
      {:error, error} -> {:error, {:invalid_bundle, error}}
    end
  end

  # JSON Schema can require a name pattern but not that the names differ. Two arms sharing one merges
  # the two conditions into a single label, which is precisely the split the study exists to make,
  # and the merge is invisible afterwards: the column says `low` for both groups.
  defp arms_distinct(decoded) do
    names =
      decoded
      |> get_in(["rules", "arms"])
      |> List.wrap()
      |> Enum.map(fn arm -> is_map(arm) && arm["name"] end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      repeated -> {:error, {:arms_share_a_name, Enum.uniq(repeated)}}
    end
  end

  # A tick treats anyone below `coverage_threshold` as protected, and coverage is only ever claimed
  # by `module_status` observations. A study that reports none, or reports them more slowly than it
  # ticks, can never clear the threshold for anybody.
  defp coverage_reportable(%{"twin" => twin} = decoded) when is_map(twin) do
    health = Map.get(decoded, "health") || %{}
    interval = Map.get(health, "interval_seconds", @default_health_interval)

    tick = Map.get(twin, "tick_interval_seconds", @default_interval)
    threshold = Map.get(twin, "coverage_threshold", @default_coverage_threshold)

    # The window in progress has not been reported yet, so at most one interval of every tick period
    # is uncovered however well the device behaves. Coverage therefore cannot exceed
    # `1 - interval/tick`, and a study needing more than that is asking for something unreachable.
    maximum = trunc(tick * (1 - threshold))

    cond do
      Map.get(health, "enabled", true) == false ->
        {:error, {:coverage_not_reported, tick}}

      interval > maximum ->
        {:error, {:health_interval_too_long, interval, maximum}}

      true ->
        :ok
    end
  end

  defp coverage_reportable(_decoded), do: :ok

  @doc "The bytes to serve for a study, byte-identical to what was registered."
  def fetch_protocol_source(id) do
    case Repo.one(from s in Study, where: s.id == ^id, select: s.protocol_source) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Attach a join code to a study.

  A code is unique across every study, not within one, so there are three outcomes and they are not
  interchangeable. A free code is attached. A code this study already holds is a no-op, which keeps
  re-seeding an unchanged bundle safe. A code belonging to *another* study is refused with
  `{:error, {:code_taken, study_id}}` rather than reported as a note: the alternative is a study
  that registers, prints an id, and has no way in, while devices using the code enrol somewhere
  else entirely.

  An `arm` on the code is refused when the protocol declares `rules.arms`. They are two different
  experiments — one stratifies by who you handed which code to, the other randomises — and only one
  can decide a participant's arm. Accepting both would let the design a researcher wrote down be
  overruled without a word.
  """
  def add_join_code(%Study{} = study, code, arm \\ nil) do
    study_id = study.id

    with :ok <- code_arm_allowed(study, arm) do
      case join_code_owner(code) do
        nil ->
          %JoinCode{}
          |> JoinCode.changeset(%{study_id: study.id, code: code, arm: arm})
          |> Repo.insert()

        %JoinCode{study_id: ^study_id} = held ->
          {:ok, held}

        %JoinCode{} = taken ->
          {:error, {:code_taken, taken.study_id}}
      end
    end
  end

  defp code_arm_allowed(_study, nil), do: :ok

  defp code_arm_allowed(%Study{protocol: protocol}, _arm) when is_map(protocol) do
    case get_in(protocol, ["rules", "arms"]) do
      list when is_list(list) -> {:error, :study_randomises_arms}
      _ -> :ok
    end
  end

  defp code_arm_allowed(_study, _arm), do: :ok

  @doc """
  Point an existing join code at a different study.

  Deliberately separate from `add_join_code/3`, because repointing a code is not a variation on
  attaching one: anybody holding it — a poster, a text message, a phone that has not re-enrolled —
  is silently redirected. For development, where the previous study is scrap, and never as a
  default.
  """
  def move_join_code(%Study{} = study, code, arm \\ nil) do
    with :ok <- code_arm_allowed(study, arm) do
      case join_code_owner(code) do
        nil ->
          add_join_code(study, code, arm)

        %JoinCode{} = held ->
          held |> JoinCode.changeset(%{study_id: study.id, arm: arm}) |> Repo.update()
      end
    end
  end

  @doc "The join code row for `code`, whichever study holds it, or nil. Case-insensitive."
  def join_code_owner(code) when is_binary(code) do
    Repo.one(from j in JoinCode, where: fragment("lower(?)", j.code) == ^String.downcase(code))
  end

  def join_code_owner(_), do: nil

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

  @doc """
  How much of a period a device must have reported itself sensing for before the study treats that
  participant as observed.

  Read from the twin block by everything that needs it. The model uses it to decide what it may
  transmit through and the rules use it to decide what may be scored, and those two must be the
  same number: a participant exposed in the simulation but unscored in the ledger is a disagreement
  no output makes visible.
  """
  def coverage_threshold(%Study{protocol: %{"twin" => %{"coverage_threshold" => threshold}}})
      when is_number(threshold) and threshold >= 0 and threshold < 1,
      do: threshold

  def coverage_threshold(_study), do: @default_coverage_threshold

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
  Every day from the first up to the one `at` falls in, or up to the last if the study has ended.

  A finished study still has days worth deciding. Refusing once the last day has passed would leave
  a study nobody ticked in time permanently unsettled, even though every one of its days is over and
  therefore decidable — and `--day <n>` would still run them one at a time.
  """
  def days_to_catch_up(%Study{} = study, at \\ DateTime.utc_now()) do
    start = starts_at(study)

    cond do
      start == nil -> {:error, :no_schedule}
      DateTime.compare(at, start) == :lt -> {:error, :not_started}
      true -> {:ok, Enum.to_list(1..(day_at(study, at) || scheduled_days(study)))}
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
