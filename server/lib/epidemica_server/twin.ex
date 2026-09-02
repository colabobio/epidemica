defmodule EpidemicaServer.Twin do
  @moduledoc """
  The twin runtime: one immutable tick per study-day.

  Elixir orchestrates and Python simulates. This module owns everything the engine must not have
  to know: which agents exist, who is protected, which contacts count, and what has already been
  decided and may never be decided again.

  A tick is immutable because participants are told its result. Once a day has been run, re-running
  it is a verification against the stored inputs and seed, never a replacement.
  """

  import Ecto.Query

  alias EpidemicaServer.{Health, Projections, Reconciliation, Repo, Studies}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Twin.{Agent, Runner, Tick}

  @default_interval 86_400
  @default_coverage_threshold 0.5
  @proximity_module "proximity"

  @doc """
  Run the twin for one study-day.

  Returns `{:error, :already_run}` if the day has been decided. That is not a failure to recover
  from: it is the guarantee that no participant's history changes after the fact.
  """
  def run_tick(study_id, day, opts \\ []) do
    with {:ok, study} <- fetch_study(study_id),
         {:ok, twin} <- twin_block(study),
         :ok <- ensure_not_run(study_id, day) do
      {period_start, period_end} = period(study, twin, day, opts)
      received_before = Keyword.get(opts, :received_before, DateTime.utc_now())

      agents = reconcile_roster(study_id, twin, day)

      inputs =
        build_inputs(study_id, twin, day, agents, period_start, period_end, received_before)

      # The engine runs outside any transaction: a subprocess that takes seconds should not hold a
      # database connection, and if it fails there is nothing to roll back because nothing has been
      # written.
      case runner(opts).(inputs) do
        {:ok, outputs} ->
          apply_tick(study_id, day, inputs, outputs, agents, %{
            period_start: period_start,
            period_end: period_end,
            received_before: received_before
          })

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-run a stored tick against its recorded inputs and compare.

  The point of storing inputs and seed is that the study's history can be checked rather than
  trusted. Nothing is written.
  """
  def verify_tick(study_id, day, opts \\ []) do
    case Repo.get_by(Tick, study_id: study_id, day: day) do
      nil ->
        {:error, :not_found}

      %Tick{} = tick ->
        case runner(opts).(tick.inputs) do
          {:ok, outputs} -> compare(outputs, tick.outputs)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp runner(opts), do: Keyword.get(opts, :runner, &Runner.run/1)

  defp compare(fresh, stored) when fresh == stored, do: :ok
  defp compare(fresh, stored), do: {:error, {:mismatch, %{recomputed: fresh, stored: stored}}}

  @doc "The agents making up a study's simulated population, in slot order."
  def agents(study_id) do
    Repo.all(from a in Agent, where: a.study_id == type(^study_id, :binary_id), order_by: a.slot)
  end

  @doc "Ticks already run for a study, oldest first."
  def ticks(study_id) do
    Repo.all(from t in Tick, where: t.study_id == type(^study_id, :binary_id), order_by: t.day)
  end

  # -- study and protocol ---------------------------------------------------------------------

  defp fetch_study(study_id) do
    case Studies.get_study(study_id) do
      nil -> {:error, :not_found}
      study -> {:ok, study}
    end
  end

  # A study without a twin block is never simulated. Refusing here rather than defaulting keeps a
  # collection-only study from quietly acquiring a model nobody asked for.
  defp twin_block(%{protocol: %{"twin" => twin}}) when is_map(twin), do: {:ok, twin}
  defp twin_block(_), do: {:error, :not_a_twin_study}

  defp ensure_not_run(study_id, day) do
    case Repo.get_by(Tick, study_id: study_id, day: day) do
      nil -> :ok
      _ -> {:error, :already_run}
    end
  end

  defp period(study, twin, day, opts) do
    interval = Map.get(twin, "tick_interval_seconds", @default_interval)
    anchor = Keyword.get(opts, :anchor, study.inserted_at)
    start = DateTime.add(anchor, (day - 1) * interval, :second)
    {start, DateTime.add(start, interval, :second)}
  end

  # -- roster ---------------------------------------------------------------------------------

  @doc """
  Bring a study's population up to date: enrol newcomers, and fill the rest with virtual agents.

  Slots are permanent. A participant joining on day four takes a slot no one has ever held, and a
  virtual agent is retired to keep the population at the size the protocol declared -- rather than
  the joiner inheriting a simulated person's infection history.
  """
  def reconcile_roster(study_id, twin, day) do
    Repo.transaction(fn ->
      existing = agents(study_id)
      existing = enrol_newcomers(study_id, day, existing)
      existing = fill_population(study_id, twin, day, existing)
      Enum.sort_by(existing, & &1.slot)
    end)
    |> case do
      {:ok, agents} -> agents
      {:error, reason} -> raise "twin roster failed: #{inspect(reason)}"
    end
  end

  defp enrol_newcomers(study_id, day, existing) do
    known = existing |> Enum.map(& &1.subject) |> MapSet.new()

    enrolled_subjects(study_id)
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.reduce(existing, fn subject, acc ->
      agent =
        insert_agent!(%{
          study_id: study_id,
          slot: next_slot(acc),
          subject: subject,
          virtual: false,
          active: true,
          joined_on_day: day
        })

      [agent | acc]
    end)
  end

  defp fill_population(study_id, twin, day, existing) do
    real = Enum.count(existing, &(not &1.virtual))
    target = max(Map.get(twin, "population", real), real)
    active = Enum.count(existing, & &1.active)

    cond do
      active < target -> add_virtual(study_id, day, existing, target - active)
      active > target -> retire_virtual(existing, active - target)
      true -> existing
    end
  end

  defp add_virtual(study_id, day, existing, count) do
    Enum.reduce(1..count//1, existing, fn _, acc ->
      agent =
        insert_agent!(%{
          study_id: study_id,
          slot: next_slot(acc),
          subject: nil,
          virtual: true,
          active: true,
          joined_on_day: day
        })

      [agent | acc]
    end)
  end

  # Retiring highest slot first is arbitrary but fixed, so the same enrolment produces the same
  # population every time.
  defp retire_virtual(existing, count) do
    doomed =
      existing
      |> Enum.filter(&(&1.active and &1.virtual))
      |> Enum.sort_by(& &1.slot, :desc)
      |> Enum.take(count)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.map(existing, fn agent ->
      if MapSet.member?(doomed, agent.id) do
        Repo.update!(Agent.changeset(agent, %{active: false}))
      else
        agent
      end
    end)
  end

  defp insert_agent!(attrs) do
    %Agent{} |> Agent.changeset(attrs) |> Repo.insert!()
  end

  defp next_slot([]), do: 0
  defp next_slot(agents), do: (agents |> Enum.map(& &1.slot) |> Enum.max()) + 1

  defp enrolled_subjects(study_id) do
    Repo.all(
      from p in Participant,
        where: p.study_id == type(^study_id, :binary_id) and is_nil(p.withdrawn_at),
        order_by: [asc: p.enrolled_at, asc: p.id],
        select: p.subject
    )
  end

  # -- inputs ---------------------------------------------------------------------------------

  # String keys throughout, because this map is written to the database and read back for
  # verification. Atom keys in memory and string keys after a reload would make a replayed tick
  # subtly different from the one that ran.
  defp build_inputs(study_id, twin, day, agents, period_start, period_end, received_before) do
    active = Enum.filter(agents, & &1.active)
    slot_to_index = active |> Enum.with_index() |> Map.new(fn {a, i} -> {a.slot, i} end)
    subject_to_index = index_by_subject(active, slot_to_index)

    protected = protected_subjects(study_id, active, period_start, period_end, twin)

    %{
      "study_id" => study_id,
      "day" => day,
      "seed" => seed_for(study_id, day),
      "population" => length(active),
      "pars" => Map.get(twin, "pars", %{}),
      "protection" => protection_pars(twin),
      "agents" =>
        Enum.map(active, fn agent ->
          %{
            "index" => Map.fetch!(slot_to_index, agent.slot),
            "subject" => agent.subject,
            "virtual" => agent.virtual,
            "state" => agent.state,
            "protected" => agent.subject != nil and MapSet.member?(protected, agent.subject),
            "infected_on_day" => agent.infected_on_day,
            "recovers_on_day" => agent.recovers_on_day,
            "dies_on_day" => agent.dies_on_day
          }
        end),
      "contacts" =>
        contacts(study_id, period_start, period_end, received_before, subject_to_index),
      "total_cases_before" => total_cases_before(study_id, day)
    }
  end

  defp index_by_subject(active, slot_to_index) do
    active
    |> Enum.reject(&(&1.subject == nil))
    |> Map.new(fn a -> {a.subject, Map.fetch!(slot_to_index, a.slot)} end)
  end

  defp contacts(study_id, from, to, received_before, subject_to_index) do
    # Idempotent, and cheap when there is nothing new. Reading the network while episodes sit
    # unprojected would quietly understate the day's exposure.
    Projections.project_contacts(study_id)

    study_id
    |> Reconciliation.network(from, to, received_before: received_before)
    |> Enum.flat_map(fn edge ->
      {a, b} = edge.pair

      case {Map.get(subject_to_index, a), Map.get(subject_to_index, b)} do
        {nil, _} ->
          []

        {_, nil} ->
          []

        {ia, ib} ->
          [
            %{
              "a" => ia,
              "b" => ib,
              "seconds" => edge.seconds,
              "band_seconds" => edge.band_seconds
            }
          ]
      end
    end)
  end

  # A participant whose device was not sensing is treated as protected rather than as having had no
  # contacts. Absence of evidence is not evidence of absence, and the alternative -- inferring that
  # a phone in a drawer met nobody -- would silently understate transmission.
  defp protected_subjects(study_id, active, from, to, twin) do
    subjects = active |> Enum.map(& &1.subject) |> Enum.reject(&is_nil/1)
    threshold = Map.get(twin, "coverage_threshold", @default_coverage_threshold)

    unobserved =
      Health.insufficiently_observed(study_id, @proximity_module, from, to, threshold, subjects)

    MapSet.new(unobserved)
  end

  defp protection_pars(twin) do
    pars = Map.get(twin, "pars", %{})
    protection = Map.get(pars, "protection", %{})

    %{
      "efficacy" => Map.get(protection, "efficacy", 1.0),
      "blocks_transmission" => Map.get(protection, "blocks_transmission", true)
    }
  end

  # Derived from the study and the day rather than drawn, so the seed is reproducible from the
  # record alone and a lost row does not make a tick unverifiable.
  defp seed_for(study_id, day), do: :erlang.phash2({study_id, day}, 2_147_483_647)

  defp total_cases_before(study_id, day) do
    Repo.one(
      from t in Tick,
        where: t.study_id == type(^study_id, :binary_id) and t.day < ^day,
        order_by: [desc: t.day],
        limit: 1,
        select: fragment("(?->>'total_cases')::int", t.outputs)
    ) || 0
  end

  # -- applying results -------------------------------------------------------------------------

  defp apply_tick(study_id, day, inputs, outputs, agents, window) do
    by_index =
      agents
      |> Enum.filter(& &1.active)
      |> Enum.with_index()
      |> Map.new(fn {agent, index} -> {index, agent} end)

    Repo.transaction(fn ->
      tick =
        %Tick{}
        |> Tick.changeset(%{
          study_id: study_id,
          day: day,
          period_start: window.period_start,
          period_end: window.period_end,
          received_before: window.received_before,
          seed: inputs["seed"],
          engine: Map.get(outputs, "engine", "starsim"),
          engine_version: Map.get(outputs, "engine_version", "unknown"),
          inputs: inputs,
          outputs: outputs,
          ran_at: DateTime.utc_now()
        })
        |> Repo.insert()

      case tick do
        {:ok, tick} ->
          Enum.each(Map.get(outputs, "agents", []), fn record ->
            agent = Map.fetch!(by_index, record["index"])

            Repo.update!(
              Agent.changeset(agent, %{
                state: record["state"],
                infected_on_day: record["infected_on_day"],
                recovers_on_day: record["recovers_on_day"],
                dies_on_day: record["dies_on_day"]
              })
            )
          end)

          tick

        {:error, changeset} ->
          Repo.rollback(rollback_reason(changeset))
      end
    end)
  end

  # The unique index is what actually enforces immutability, so a losing writer is reported as
  # "already run" rather than as a database error.
  defp rollback_reason(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :study_id) or Keyword.has_key?(errors, :day),
      do: :already_run,
      else: {:invalid_tick, errors}
  end
end
