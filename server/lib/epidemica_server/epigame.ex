defmodule EpidemicaServer.Epigame do
  @moduledoc """
  Scoring a study's days, and publishing the result to participants.

  The twin decides what happened; this decides what it was worth. They are separate because a study
  may simulate without scoring or score without simulating, and because points must never depend on
  anything the participant was not already shown.

  A settled day is immutable. A contact whose other side arrives afterwards is credited to the next
  settlement rather than rewriting one a participant has already seen.
  """

  import Ecto.Query

  alias EpidemicaServer.{Health, ParticipantState, Reconciliation, Repo, Studies}
  alias EpidemicaServer.Epigame.{LedgerEntry, Rules}
  alias EpidemicaServer.Twin.Tick

  @proximity_module "proximity"

  @doc """
  Settle one study-day for every enrolled participant.

  Requires the day's tick, because a participant's epidemiological state is what the tick published
  and points are a function of published state.
  """
  def settle_day(study_id, day, opts \\ []) do
    with {:ok, study} <- fetch_study(study_id),
         {:ok, rules} <- rules_block(study),
         {:ok, tick} <- fetch_tick(study_id, day) do
      pars = Rules.pars(rules)
      now = Keyword.get(opts, :now, DateTime.utc_now())

      subjects = participants_in(tick)
      shown = states_shown_during(study_id, day, subjects)
      observed = observed_subjects(study_id, tick, subjects, pars)
      chosen = chosen_protection(study_id, tick.period_start, tick.period_end)

      awards = award_day(study_id, day, tick, pars, chosen, observed)
      carried = award_carry_over(study_id, day, study, pars, chosen)

      settlements =
        Enum.map(subjects, fn subject ->
          facts = %{
            day: day,
            opening: balance(study_id, subject),
            epi_state: Map.get(shown, subject, "susceptible"),
            observed: MapSet.member?(observed, subject),
            protection: protection_source(subject, chosen, observed),
            contacts: Map.get(awards, subject, 0),
            carried_over: Map.get(carried, subject, 0)
          }

          {subject, Rules.settle(pars, facts)}
        end)

      write(study_id, day, settlements, tick, pars, shown, chosen, observed, now)
    end
  end

  @doc "A participant's current balance: the closing figure of the last day settled for them."
  def balance(study_id, subject) do
    Repo.one(
      from e in LedgerEntry,
        where: e.study_id == type(^study_id, :binary_id) and e.subject == ^subject,
        order_by: [desc: e.day],
        limit: 1,
        select: e.closing
    ) || 0
  end

  @doc "Every day settled for a participant, oldest first."
  def ledger(study_id, subject) do
    Repo.all(
      from e in LedgerEntry,
        where: e.study_id == type(^study_id, :binary_id) and e.subject == ^subject,
        order_by: e.day
    )
  end

  # -- protection as a recorded action ------------------------------------------------------------

  @doc """
  Take protection from `at` until the bundle's window expires.

  Recorded with a time rather than held as a flag, so that "I was protected all along" is answerable
  from the record.
  """
  def protect(study_id, subject, at \\ DateTime.utc_now(), pars \\ %{}) do
    window = Map.get(Rules.pars(%{"pars" => pars}), "protection_window_seconds")

    Repo.insert_all(
      "game_actions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          study_id: Ecto.UUID.dump!(study_id),
          subject: subject,
          type: "protect",
          effective_from: at,
          effective_until: DateTime.add(at, window, :second),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ],
      []
    )

    :ok
  end

  @doc "Release protection early. Does not refund the day already charged for."
  def release(study_id, subject, at \\ DateTime.utc_now()) do
    {count, _} =
      Repo.update_all(
        from(a in "game_actions",
          where:
            a.study_id == type(^study_id, :binary_id) and a.subject == ^subject and
              a.type == "protect" and a.effective_from <= ^at and a.effective_until > ^at
        ),
        set: [effective_until: at]
      )

    if count > 0, do: :ok, else: {:error, :not_protected}
  end

  @doc "Subjects who chose protection covering any part of `[from, to)`."
  def chosen_protection(study_id, from, to) do
    Repo.all(
      from a in "game_actions",
        where:
          a.study_id == type(^study_id, :binary_id) and a.type == "protect" and
            a.effective_from < ^to and a.effective_until > ^from,
        select: a.subject,
        distinct: true
    )
    |> MapSet.new()
  end

  # -- internals ----------------------------------------------------------------------------------

  defp fetch_study(study_id) do
    case Studies.get_study(study_id) do
      nil -> {:error, :not_found}
      study -> {:ok, study}
    end
  end

  defp rules_block(%{protocol: %{"rules" => rules}}) when is_map(rules), do: {:ok, rules}
  defp rules_block(_), do: {:error, :not_a_scored_study}

  defp fetch_tick(study_id, day) do
    case Repo.get_by(Tick, study_id: study_id, day: day) do
      nil -> {:error, :no_tick}
      tick -> {:ok, tick}
    end
  end

  defp participants_in(tick) do
    tick.inputs
    |> Map.get("agents", [])
    |> Enum.reject(&(&1["subject"] == nil))
    |> Enum.map(& &1["subject"])
  end

  # The state the participant was looking at *during* the day, which is what the previous tick
  # published. Using the state this tick just produced would score people for news they had not
  # yet been given.
  defp states_shown_during(study_id, day, subjects) do
    case Repo.get_by(Tick, study_id: study_id, day: day - 1) do
      nil ->
        Map.new(subjects, &{&1, "susceptible"})

      previous ->
        previous.outputs
        |> Map.get("agents", [])
        |> Enum.reject(&(&1["subject"] == nil))
        |> Map.new(&{&1["subject"], &1["state"]})
    end
  end

  defp observed_subjects(study_id, tick, subjects, pars) do
    threshold = Map.get(pars, "coverage_threshold", 0.5)

    unobserved =
      Health.insufficiently_observed(
        study_id,
        @proximity_module,
        tick.period_start,
        tick.period_end,
        threshold,
        subjects
      )
      |> MapSet.new()

    subjects |> Enum.reject(&MapSet.member?(unobserved, &1)) |> MapSet.new()
  end

  defp protection_source(subject, chosen, observed) do
    cond do
      MapSet.member?(chosen, subject) -> "chosen"
      not MapSet.member?(observed, subject) -> "not_sensing"
      true -> nil
    end
  end

  defp award_day(study_id, day, tick, pars, chosen, observed) do
    network =
      Reconciliation.network(study_id, tick.period_start, tick.period_end,
        received_before: tick.received_before
      )

    record_awards(study_id, day, day, network, pars, chosen, observed)
  end

  # Days already settled are revisited only to find contacts whose other side had not yet arrived.
  # Their own settlements are untouched; the credit lands here instead.
  defp award_carry_over(study_id, day, study, pars, chosen) do
    lookback = Map.get(pars, "carry_over_days", 3)
    twin = Map.get(study.protocol, "twin", %{})
    interval = Map.get(twin, "tick_interval_seconds", 86_400)

    Enum.reduce(max(day - lookback, 1)..(day - 1)//1, %{}, fn earlier, acc ->
      case Repo.get_by(Tick, study_id: study_id, day: earlier) do
        nil ->
          acc

        past ->
          network =
            Reconciliation.network(study_id, past.period_start, past.period_end,
              received_before: DateTime.add(past.period_end, interval * lookback, :second)
            )

          observed_then = observed_subjects(study_id, past, participants_in(past), pars)
          counts = record_awards(study_id, earlier, day, network, pars, chosen, observed_then)
          Map.merge(acc, counts, fn _k, a, b -> a + b end)
      end
    end)
  end

  defp record_awards(study_id, contact_day, awarded_on_day, network, pars, chosen, observed) do
    # A participant the study could not hear from is not credited: the contact cannot be attested
    # any more than the day can.
    unavailable =
      network
      |> Enum.flat_map(fn e -> Tuple.to_list(e.pair) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(observed, &1))
      |> MapSet.new()
      |> MapSet.union(chosen)

    already = awarded_pairs(study_id, contact_day, pars, awarded_on_day)

    pairs = Rules.award_contacts(pars, network, unavailable, already)

    rows =
      Enum.flat_map(pairs, fn {a, b} ->
        [{a, b}, {b, a}]
      end)
      |> Enum.map(fn {subject, peer} ->
        %{
          id: Ecto.UUID.bingenerate(),
          study_id: Ecto.UUID.dump!(study_id),
          subject: subject,
          peer: peer,
          day: contact_day,
          awarded_on_day: awarded_on_day,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    {_, inserted} =
      Repo.insert_all("game_contact_awards", rows,
        on_conflict: :nothing,
        conflict_target: [:study_id, :subject, :peer, :day],
        returning: [:subject]
      )

    Enum.frequencies(Enum.map(inserted, & &1.subject))
  end

  # Pairs that must not be paid again: those already credited for this exact day, and those the
  # cooldown still covers.
  defp awarded_pairs(study_id, contact_day, pars, _awarded_on_day) do
    cooldown = Map.get(pars, "contact_cooldown_days", 1)

    Repo.all(
      from a in "game_contact_awards",
        where:
          a.study_id == type(^study_id, :binary_id) and a.day <= ^contact_day and
            a.day >= ^(contact_day - cooldown),
        select: {a.subject, a.peer}
    )
    |> MapSet.new()
  end

  defp write(study_id, day, settlements, tick, pars, shown, chosen, observed, now) do
    Repo.transaction(fn ->
      Enum.each(settlements, fn {subject, settlement} ->
        entry =
          %LedgerEntry{}
          |> LedgerEntry.changeset(%{
            study_id: study_id,
            subject: subject,
            day: day,
            closing: settlement.closing,
            settlement: stringify(settlement),
            settled_at: now
          })
          |> Repo.insert()

        case entry do
          {:ok, _} ->
            publish(study_id, subject, day, settlement, tick, pars, shown, chosen, observed)

          {:error, changeset} ->
            Repo.rollback(reason_for(changeset))
        end
      end)

      day
    end)
  end

  defp reason_for(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :study_id) or Keyword.has_key?(errors, :day),
      do: :already_settled,
      else: {:invalid_settlement, errors}
  end

  defp publish(study_id, subject, day, settlement, tick, pars, shown, chosen, observed) do
    state = %{
      "day" => day,
      "days_total" => Map.get(pars, "days_total", 7),
      "epi_state" => current_state(tick, subject, shown),
      "points" => settlement.closing,
      "protection_source" => protection_source(subject, chosen, observed),
      "total_cases" => Map.get(tick.outputs, "total_cases", 0),
      "population" => Map.get(tick.inputs, "population", 0),
      "settlement" => stringify(settlement)
    }

    state_uri = "https://schemas.epidemica.info/state/epigame/1.0.0.json"

    case ParticipantState.put(study_id, subject, state_uri, state) do
      {:ok, _} -> :ok
      {:error, :no_such_participant} -> :ok
    end
  end

  # What the participant is shown *now* is this tick's outcome, even though it is tomorrow's
  # earnings that depend on it.
  defp current_state(tick, subject, shown) do
    tick.outputs
    |> Map.get("agents", [])
    |> Enum.find(&(&1["subject"] == subject))
    |> case do
      nil -> Map.get(shown, subject, "susceptible")
      agent -> agent["state"]
    end
  end

  defp stringify(%{} = map) do
    Map.new(map, fn
      {k, v} when is_list(v) -> {to_string(k), Enum.map(v, &stringify/1)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
