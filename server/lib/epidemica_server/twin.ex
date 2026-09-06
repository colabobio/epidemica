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

  alias EpidemicaServer.{Epigame, Health, Projections, Reconciliation, Repo, Studies}
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Studies.Study
  alias EpidemicaServer.Twin.{Agent, Runner, Tick}

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
         :ok <- ensure_in_schedule(study, day),
         :ok <- ensure_not_run(study_id, day) do
      {period_start, period_end} = period(study, twin, day, opts)
      received_before = Keyword.get(opts, :received_before, DateTime.utc_now())

      with :ok <- ensure_elapsed(period_end, received_before, opts) do
        agents = reconcile_roster(study_id, twin, day)
        inputs = build_inputs(study, twin, day, agents, period_start, period_end, received_before)

        # The engine runs outside any transaction: a subprocess that takes seconds should not hold
        # a database connection, and if it fails there is nothing to roll back because nothing has
        # been written.
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

  # A study ends. Running past its last day would keep an epidemic going after participants had been
  # shown a final score, and running before day one would score a game nobody had started.
  defp ensure_in_schedule(study, day) do
    days = Studies.scheduled_days(study)

    cond do
      day < 1 -> {:error, :before_study_start}
      days != nil and day > days -> {:error, :after_study_end}
      true -> :ok
    end
  end

  # Anchored on the declared start, not on when the study happened to be registered: re-registering
  # a bundle must not move a boundary that participants' days are numbered from.
  # A day is only decidable once it is over. Ticking one still in progress -- or, worse, still in the
  # future -- settles it on a network that has not happened yet, and because a tick is immutable
  # that wrong answer is permanent. `allow_incomplete: true` is for tests and demonstrations, where
  # nobody is waiting a real day.
  defp ensure_elapsed(period_end, received_before, opts) do
    cond do
      Keyword.get(opts, :allow_incomplete, false) -> :ok
      DateTime.compare(period_end, received_before) != :gt -> :ok
      true -> {:error, :day_not_finished}
    end
  end

  defp period(study, _twin, day, opts) do
    interval = Studies.tick_interval(study)
    anchor = Keyword.get(opts, :anchor) || Studies.starts_at(study) || study.inserted_at
    start = DateTime.add(anchor, (day - 1) * interval, :second)
    {start, DateTime.add(start, interval, :second)}
  end

  # -- roster ---------------------------------------------------------------------------------

  @doc """
  Bring a study's population up to date: enroll newcomers, and fill the rest with virtual agents.

  Slots are permanent. A participant joining on day four takes a slot no one has ever held, and a
  virtual agent is retired to keep the population at the size the protocol declared -- rather than
  the joiner inheriting a simulated person's infection history.
  """
  def reconcile_roster(study_id, twin, day) do
    Repo.transaction(fn ->
      existing = agents(study_id)
      existing = enroll_newcomers(study_id, day, existing)
      existing = remove_finished(study_id, twin, day, existing)
      existing = fill_population(study_id, twin, day, existing)
      existing = seed_outbreak(study_id, twin, day, existing)
      Enum.sort_by(existing, & &1.slot)
    end)
    |> case do
      {:ok, agents} -> agents
      {:error, reason} -> raise "twin roster failed: #{inspect(reason)}"
    end
  end

  @doc """
  Infect the study's index cases, once, before its first day.

  Without this nobody is ever infected and a study runs to completion having simulated nothing —
  which on screen is indistinguishable from a disease that failed to spread.

  Who is chosen is derived from the study and the slot rather than drawn, so the same study always
  starts the same way and a replayed history matches. The default pool is the virtual population:
  a real participant infected on day one loses most of the game to a lottery they can neither see
  nor influence, and every real infection then has a contact behind it instead of an unexplainable
  beginning.
  """
  def seed_outbreak(study_id, twin, day, existing) do
    seed = Map.get(twin, "seed") || %{}
    count = Map.get(seed, "infections", 0)
    already_seeded? = Enum.any?(existing, &(&1.infected_on_day != nil))

    cond do
      count == 0 ->
        existing

      # First tick: seed the index cases once, before anything has run.
      not already_seeded? ->
        seed_agents(study_id, day, existing, count, Map.get(seed, "among", "virtual"))

      # An open-ended study whose outbreak has died out is not a study at all — it is a contact
      # log with a simulation attached that is simulating nothing. Re-seed it rather than letting
      # it run to completion having produced an empty epidemic.
      reseed_outbreak?(study_id, day, existing) ->
        seed_agents(study_id, day, existing, count, Map.get(seed, "among", "virtual"))

      true ->
        existing
    end
  end

  # Whether the outbreak has died out and needs re-seeding. A study with a last day never reaches
  # this: its epidemic is allowed to burn out, because that is the answer to the question the study
  # exists to ask. A study with no last day cannot afford that answer, because it would then run
  # forever having simulated nothing.
  defp reseed_outbreak?(study_id, day, existing) do
    days = Studies.scheduled_days(Repo.get!(Study, study_id))
    open_ended = days == nil

    open_ended and no_active_infections(existing) and ticks_exist?(study_id, day)
  end

  defp no_active_infections(existing) do
    Enum.all?(existing, &(&1.state in ["susceptible", "recovered"] or not &1.active))
  end

  defp ticks_exist?(study_id, _day) do
    Repo.exists?(from t in Tick, where: t.study_id == type(^study_id, :binary_id))
  end

  defp seed_agents(study_id, day, existing, count, among) do
    chosen =
      existing
      |> Enum.filter(&(&1.active and eligible?(&1, among)))
      |> Enum.sort_by(&:erlang.phash2({study_id, &1.slot}))
      |> Enum.take(count)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.map(existing, fn agent ->
      if MapSet.member?(chosen, agent.id) do
        Repo.update!(Agent.changeset(agent, %{state: "infected", infected_on_day: day - 1}))
      else
        agent
      end
    end)
  end

  defp eligible?(_agent, "any"), do: true
  defp eligible?(agent, "participants"), do: not agent.virtual
  defp eligible?(agent, _virtual), do: agent.virtual

  defp enroll_newcomers(study_id, day, existing) do
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

  # A dead agent is gone, and a virtual agent past its declared lifetime is retired. Both free a
  # slot that fill_population will refill on the same tick. A real participant is never removed
  # this way — their leaving is their own decision, not the model's.
  defp remove_finished(study_id, twin, day, existing) do
    turnover = Map.get(twin, "turnover_after_days")
    grace = Map.get(twin, "finished_grace_days")

    doomed =
      existing
      |> Enum.filter(& &1.active)
      |> Enum.filter(fn agent ->
        cond do
          # A dead agent is gone now, regardless of what it was.
          agent.state == "dead" -> true
          # A virtual agent retired by age. turnover_after_days is the study's declared lifetime;
          # absent or zero means never retire.
          agent.virtual and turnover != nil and turnover > 0 and
              day - agent.joined_on_day >= turnover -> true
          # A real participant whose grace period has elapsed after reaching a final state.
          not agent.virtual and grace != nil and grace > 0 and
            agent.state in ["recovered", "dead"] and
            day - (agent.recovers_on_day || agent.dies_on_day || day) >= grace -> true
          # A real participant whose phone has gone quiet: no observation in
          # `sync.min_interval_seconds` × 4. The study's way of not keeping a slot for someone
          # who uninstalled the app and is definitely not coming back.
          not agent.virtual and quiet?(study_id, agent.subject, twin) -> true
          true -> false
        end
      end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if MapSet.size(doomed) == 0 do
      existing
    else
      # Tell the participant before removing them: a study with no last day never finishes, so
      # without this their app would keep showing a running game to someone who is no longer in it.
      for agent <- existing, MapSet.member?(doomed, agent.id), not agent.virtual do
        publish_finished(study_id, agent.subject, day, agent.state)
      end

      Enum.map(existing, fn agent ->
        if MapSet.member?(doomed, agent.id) do
          Repo.update!(Agent.changeset(agent, %{active: false}))
        else
          agent
        end
      end)
    end
  end

  # A participant who has not uploaded anything in the study's sync window is not playing.
  defp quiet?(study_id, subject, twin) do
    interval = Map.get(twin, "min_interval_seconds")
    # No declared sync interval means no way to say what "quiet" is — a study that never said how
    # often it expected to hear from a phone cannot be used to conclude one has stopped.
    if interval == nil or interval <= 0 do
      false
    else
      window_seconds = interval * 4
      since = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

      not Repo.exists?(
        from o in EpidemicaServer.Ingest.Observation,
          where:
            o.study_id == type(^study_id, :binary_id) and
              o.subject == ^subject and
              o.received_at > ^since
      )
    end
  end

  # The study is still running; only this participant's part in it has ended. `days_total` is the
  # day their game ended rather than the study's own, which is the one the app needs to render
  # "Finished" against.
  defp publish_finished(study_id, subject, day, final_state) do
    case Epigame.publish_finished(study_id, subject, day, final_state) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback({:could_not_publish_finished, subject, reason})
    end
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

  # Retiring highest slot first is arbitrary but fixed, so the same enrollment produces the same
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
  defp build_inputs(study, twin, day, agents, period_start, period_end, received_before) do
    study_id = study.id
    active = Enum.filter(agents, & &1.active)
    slot_to_index = active |> Enum.with_index() |> Map.new(fn {a, i} -> {a.slot, i} end)
    subject_to_index = index_by_subject(active, slot_to_index)

    protection = protection_levels(study, active, period_start, period_end, twin)

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
            "protection" => Map.get(protection, agent.subject, 0.0),
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

  # Two independent sources. The platform infers protection from missing coverage — a phone in a
  # drawer must not be read as a participant who met nobody — and the study's rules contribute
  # whatever protection a participant chose. Neither can see the other's case.
  #
  # A participant the study could not hear from is protected outright rather than proportionally:
  # no part of their day can be attested, so letting the model transmit through any of it would be
  # a claim the data does not support. A chosen protection is different — it is known exactly, to
  # the second, and applies for as much of the day as it actually covered.
  defp protection_levels(study, active, from, to, twin) do
    subjects = active |> Enum.map(& &1.subject) |> Enum.reject(&is_nil/1)
    threshold = Map.get(twin, "coverage_threshold", @default_coverage_threshold)

    unobserved =
      Health.insufficiently_observed(study.id, @proximity_module, from, to, threshold, subjects)
      |> MapSet.new()

    chosen = chosen_protection_levels(study, from, to)

    Map.new(subjects, fn subject ->
      if MapSet.member?(unobserved, subject) do
        {subject, 1.0}
      else
        {subject, Map.get(chosen, subject, 0.0)}
      end
    end)
  end

  defp chosen_protection_levels(
         %{protocol: %{"rules" => %{"engine" => "epigame"}}} = study,
         from,
         to
       ) do
    EpidemicaServer.Epigame.protection_fractions(study.id, from, to)
  end

  defp chosen_protection_levels(_study, _from, _to), do: %{}

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
