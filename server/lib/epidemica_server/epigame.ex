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
  alias EpidemicaServer.Enrollment.Participant
  alias EpidemicaServer.Epigame.{LedgerEntry, Rules}
  alias EpidemicaServer.Twin.Tick

  @proximity_module "proximity"
  @state_uri "https://schemas.epidemica.info/state/epigame/1.0.0.json"

  @doc """
  Publish the state a participant starts with.

  Without it there is nothing to render until the first tick lands, and a blank screen for a whole
  day reads as a broken study rather than one that has not decided anything yet. `susceptible` is
  not a guess: seeding runs at the first tick, so nobody is infected before one has happened.

  Does nothing if a state already exists, because re-enrolling after a reinstall must not reset a
  participant to day zero.
  """
  def publish_initial(study_id, subject) do
    with {:ok, study} <- fetch_study(study_id),
         {:ok, _rules} <- rules_block(study),
         {:error, :not_found} <- ParticipantState.fetch(study_id, subject) do
      state =
        %{
          "day" => 0,
          "days_total" => Studies.scheduled_days(study),
          "epi_state" => "susceptible",
          "points" => 0,
          "protected_until" => nil,
          "protection_source" => nil,
          "pending_contacts" => 0,
          "total_cases" => 0
        }
        |> put_population(study)

      ParticipantState.put(study_id, subject, @state_uri, state)
    else
      {:ok, _already_has_state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Omitted rather than zeroed for a study with no twin: the contract requires a population of at
  # least one because `total_cases` is meaningless without it, and inventing a size to satisfy that
  # would be worse than saying nothing.
  defp put_population(state, %{protocol: %{"twin" => %{"population" => n}}}) when is_integer(n),
    do: Map.put(state, "population", n)

  defp put_population(state, _study), do: state

  @doc """
  Settle one study-day for every enrolled participant.

  Requires the day's tick, because a participant's epidemiological state is what the tick published
  and points are a function of published state.
  """
  def settle_day(study_id, day, opts \\ []) do
    with {:ok, study} <- fetch_study(study_id),
         {:ok, rules} <- rules_block(study),
         {:ok, tick} <- fetch_tick(study_id, day) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      arms = arms_by_subject(study_id)
      subjects = participants_in(tick)
      shown = states_shown_during(study_id, day, subjects)
      observed = observed_subjects(study_id, tick, subjects)
      chosen = chosen_protection(study_id, tick.period_start, tick.period_end)

      awards = award_day(study_id, day, tick, rules, arms, chosen, observed)
      carried = award_carry_over(study_id, day, study, rules, arms)

      settlements =
        Enum.map(subjects, fn subject ->
          pars = pars_for_subject(rules, arms, subject)

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

      write(study_id, day, settlements, tick, study, shown, chosen, observed, now)
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
  def protect(study_id, subject, at \\ DateTime.utc_now(), pars_override \\ %{}) do
    window =
      case pars_override do
        %{} = override when map_size(override) > 0 ->
          Rules.pars(%{"pars" => override})["protection_window_seconds"]

        _ ->
          # Read from the study, overlaid with the participant's arm, so a study that makes
          # protection longer for one group is honoured rather than charged at the shared window.
          case fetch_study(study_id) do
            {:ok, study} ->
              rules = Map.get(study.protocol, "rules", %{})

              Rules.pars_for(rules, participant_arm(study_id, subject))[
                "protection_window_seconds"
              ]

            {:error, _} ->
              Rules.pars(%{})["protection_window_seconds"]
          end
      end

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

    publish_protection(study_id, subject, at)
    {:ok, protected_until(study_id, subject, at)}
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

    if count > 0 do
      publish_protection(study_id, subject, at)
      :ok
    else
      {:error, :not_protected}
    end
  end

  @doc "When a participant's chosen protection lapses, or nil when they have none running."
  def protected_until(study_id, subject, at \\ DateTime.utc_now()) do
    Repo.one(
      from a in "game_actions",
        where:
          a.study_id == type(^study_id, :binary_id) and a.subject == ^subject and
            a.type == "protect" and a.effective_from <= ^at and a.effective_until > ^at,
        select: max(a.effective_until)
    )
    |> to_utc()
  end

  # Protection is the participant's own decision, so it is published the instant it is taken rather
  # than at settlement. The contract carries `protected_until` as an instant for exactly this: a
  # player who taps "protect" and sees nothing change until tomorrow cannot connect the act to its
  # consequence, which is the thing the game exists to teach.
  #
  # Only `protected_until` is touched. `protection_source` says why a *settled* day was protected,
  # which research needs in order to tell a deliberate choice from a phone that stopped sensing;
  # overwriting it here would destroy that distinction on the next tap.
  defp publish_protection(study_id, subject, at) do
    case ParticipantState.fetch(study_id, subject) do
      {:ok, %{state: state}} ->
        updated = Map.put(state, "protected_until", iso(protected_until(study_id, subject, at)))
        ParticipantState.put(study_id, subject, @state_uri, updated)

      {:error, :not_found} ->
        :ok
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # A schemaless query has no schema to say the column is UTC, so it arrives naive.
  defp to_utc(nil), do: nil
  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  @doc """
  How much of `[from, to)` each participant's chosen protection covered, as a fraction of it.

  Protection applies from the moment it is taken, so protecting at noon protects half a day and
  releasing an hour later protects a twenty-fourth of one. Treating any overlap as a whole day
  would let a participant be exposed all day, protect at the last minute, and be modelled as immune
  for contacts that had already happened.

  Overlapping and repeated actions are unioned rather than summed: tapping protect twice cannot
  claim more of a day than the day contains.
  """
  def protection_fractions(study_id, from, to) do
    window = DateTime.diff(to, from, :microsecond)

    if window <= 0 do
      %{}
    else
      Repo.all(
        from a in "game_actions",
          where:
            a.study_id == type(^study_id, :binary_id) and a.type == "protect" and
              a.effective_from < ^to and a.effective_until > ^from,
          select: {a.subject, a.effective_from, a.effective_until}
      )
      |> Enum.group_by(
        fn {subject, _, _} -> subject end,
        fn {_, starts, ends} -> {to_utc(starts), to_utc(ends)} end
      )
      |> Map.new(fn {subject, intervals} ->
        {subject, covered_microseconds(intervals, from, to) / window}
      end)
    end
  end

  @doc "Subjects who chose protection covering any part of `[from, to)`."
  def chosen_protection(study_id, from, to) do
    study_id |> protection_fractions(from, to) |> Map.keys() |> MapSet.new()
  end

  defp covered_microseconds(intervals, from, to) do
    intervals
    |> Enum.map(fn {starts, ends} -> {later(starts, from), earlier(ends, to)} end)
    |> Enum.filter(fn {starts, ends} -> DateTime.compare(starts, ends) == :lt end)
    |> Enum.sort_by(fn {starts, _} -> DateTime.to_unix(starts, :microsecond) end)
    |> Enum.reduce({0, nil}, fn {starts, ends}, {total, open} ->
      case open do
        nil ->
          {total, {starts, ends}}

        {open_start, open_end} ->
          if DateTime.compare(starts, open_end) != :gt do
            {total, {open_start, later(open_end, ends)}}
          else
            {total + DateTime.diff(open_end, open_start, :microsecond), {starts, ends}}
          end
      end
    end)
    |> then(fn
      {total, nil} -> total
      {total, {open_start, open_end}} -> total + DateTime.diff(open_end, open_start, :microsecond)
    end)
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  # -- contacts a participant has earned but not yet been paid for -------------------------------

  @doc """
  How many long-enough contacts a participant has had since the last tick.

  Reported so the app can say something is coming without keeping a second ledger. It is not a
  promise of points: whether a contact pays depends on protection and cooldown, which are decided
  when the day settles.
  """
  def pending_contacts(study_id, subject, now \\ DateTime.utc_now()) do
    with {:ok, study} <- fetch_study(study_id),
         {:ok, rules} <- rules_block(study),
         since when since != nil <- pending_since(study_id, study, subject),
         :lt <- DateTime.compare(since, now) do
      minimum =
        Rules.pars_for(rules, participant_arm(study_id, subject))["contact_min_seconds"]

      study_id
      |> Reconciliation.network(since, now)
      |> Enum.count(fn edge ->
        {a, b} = edge.pair
        (a == subject or b == subject) and edge.seconds >= minimum
      end)
    else
      _ -> 0
    end
  end

  @doc """
  Recompute a participant's pending contacts and publish them if the number moved.

  Only writes on a change, so a device syncing every minute does not churn the document's revision
  and make every poll look like news.
  """
  def refresh_pending(study_id, subject, now \\ DateTime.utc_now()) do
    case ParticipantState.fetch(study_id, subject) do
      {:ok, %{state: state}} ->
        count = pending_contacts(study_id, subject, now)

        if state["pending_contacts"] == count do
          :ok
        else
          ParticipantState.put(
            study_id,
            subject,
            @state_uri,
            Map.put(state, "pending_contacts", count)
          )
        end

      {:error, :not_found} ->
        :ok
    end
  end

  # Everything after the last decided day is still open. Before the first tick that is the study's
  # start, and for a study with no schedule it is when the participant joined -- never earlier, or
  # a newcomer would inherit contacts made before they existed.
  defp pending_since(study_id, study, subject) do
    last_tick_end(study_id) || Studies.starts_at(study) || enrolled_at(study_id, subject)
  end

  defp last_tick_end(study_id) do
    Repo.one(
      from t in Tick,
        where: t.study_id == type(^study_id, :binary_id),
        order_by: [desc: t.day],
        limit: 1,
        select: t.period_end
    )
    |> to_utc()
  end

  defp enrolled_at(study_id, subject) do
    Repo.one(
      from p in Participant,
        where: p.study_id == type(^study_id, :binary_id) and p.subject == ^subject,
        select: p.enrolled_at
    )
    |> to_utc()
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

  # Every participant's arm, once, so a caller scoring a whole day does not ask the database for
  # each subject in turn.
  defp arms_by_subject(study_id) do
    Repo.all(
      from p in Participant,
        where: p.study_id == type(^study_id, :binary_id) and is_nil(p.withdrawn_at),
        select: {p.subject, p.arm}
    )
    |> Map.new()
  end

  defp pars_for_subject(rules, arms, subject), do: Rules.pars_for(rules, Map.get(arms, subject))

  # A participant's arm, or nil for a study that does not randomise. Read here rather than passed
  # down from every caller, because the arm is the only thing an action should be priced by and it
  # has to be the same answer scoring reaches.
  defp participant_arm(study_id, subject) do
    Repo.one(
      from p in Participant,
        where: p.study_id == type(^study_id, :binary_id) and p.subject == ^subject,
        select: p.arm
    )
  end

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

  defp observed_subjects(study_id, tick, subjects) do
    unobserved =
      Health.insufficiently_observed(
        study_id,
        @proximity_module,
        tick.period_start,
        tick.period_end,
        0.5,
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

  defp award_day(study_id, day, tick, rules, arms, chosen, observed) do
    network =
      Reconciliation.network(study_id, tick.period_start, tick.period_end,
        received_before: tick.received_before
      )

    record_awards(study_id, day, day, network, rules, arms, chosen, observed)
  end

  # Days already settled are revisited only to find contacts whose other side had not yet arrived.
  # Their own settlements are untouched; the credit lands here instead.
  defp award_carry_over(study_id, day, study, rules, arms) do
    interval = Studies.tick_interval(study)
    # The furthest any participant can look back, which is the most generous arm's. Reaching no
    # further would deny the credits a longer window was entitled to.
    lookback = max_longest(rules, arms, "carry_over_days")

    Enum.reduce(max(day - lookback, 1)..(day - 1)//1, %{}, fn earlier, acc ->
      case Repo.get_by(Tick, study_id: study_id, day: earlier) do
        nil ->
          acc

        past ->
          network =
            Reconciliation.network(study_id, past.period_start, past.period_end,
              received_before: DateTime.add(past.period_end, interval * lookback, :second)
            )

          # Every fact used to judge a late contact is the one that held on the day of the contact,
          # not today. Protection removes the reward as well as the risk, so paying a participant
          # now for a contact they made while protected refunds a cost they agreed to -- and the
          # mirror case would deny someone contacts they earned before protecting.
          chosen_then = chosen_protection(study_id, past.period_start, past.period_end)
          observed_then = observed_subjects(study_id, past, participants_in(past))

          counts =
            record_awards(
              study_id,
              earlier,
              day,
              network,
              rules,
              arms,
              chosen_then,
              observed_then
            )

          Map.merge(acc, counts, fn _k, a, b -> a + b end)
      end
    end)
  end

  # Scores a pair by the more permissive of its two arms. A contact is worth what it is worth to
  # the participant who was there, and the only defensible reading when two players are scored
  # differently is to charge each of them by the rules they were shown.
  defp record_awards(
         study_id,
         contact_day,
         awarded_on_day,
         network,
         rules,
         arms,
         chosen,
         observed
       ) do
    unavailable =
      network
      |> Enum.flat_map(fn e -> Tuple.to_list(e.pair) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(observed, &1))
      |> MapSet.new()
      |> MapSet.union(chosen)

    already = awarded_pairs(study_id, contact_day, rules, arms)

    pairs =
      network
      |> Enum.filter(fn edge ->
        {a, b} = edge.pair

        qualifies_by?(edge, pars_for_subject(rules, arms, a), unavailable, already) or
          qualifies_by?(edge, pars_for_subject(rules, arms, b), unavailable, already)
      end)
      |> Enum.map(& &1.pair)

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

  defp qualifies_by?(edge, pars, unavailable, already) do
    {a, b} = edge.pair

    edge.seconds >= pars["contact_min_seconds"] and
      not MapSet.member?(unavailable, a) and
      not MapSet.member?(unavailable, b) and
      not MapSet.member?(already, edge.pair)
  end

  # Pairs that must not be paid again: those already credited for this exact day, and those still
  # inside the longest cooldown any arm declares, since a pair the rules disagree about is judged by
  # the arm whose window is longer.
  defp awarded_pairs(study_id, contact_day, rules, arms) do
    cooldown = max_longest(rules, arms, "contact_cooldown_days")

    Repo.all(
      from a in "game_contact_awards",
        where:
          a.study_id == type(^study_id, :binary_id) and a.day <= ^contact_day and
            a.day >= ^(contact_day - cooldown),
        select: {a.subject, a.peer}
    )
    |> MapSet.new()
  end

  # The largest value of a rule across every arm in play, so a window shared by a pair is never
  # shorter than either side's.
  defp max_longest(rules, arms, key) do
    ([Rules.pars(rules)[key]] ++
       Enum.map(Map.keys(arms), fn subject -> pars_for_subject(rules, arms, subject)[key] end))
    |> Enum.max()
  end

  defp write(study_id, day, settlements, tick, study, shown, chosen, observed, now) do
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
            publish(study_id, subject, day, settlement, tick, study, shown, chosen, observed)

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

  defp publish(study_id, subject, day, settlement, tick, study, shown, chosen, observed) do
    state = %{
      "day" => day,
      # Null when the study declares no schedule. Reporting the current day as the total would
      # tell a player on day one that the game had ended.
      "days_total" => Studies.scheduled_days(study),
      "epi_state" => current_state(tick, subject, shown),
      "points" => settlement.closing,
      "protected_until" => iso(protected_until(study_id, subject)),
      "protection_source" => protection_source(subject, chosen, observed),
      "pending_contacts" => pending_contacts(study_id, subject),
      "total_cases" => Map.get(tick.outputs, "total_cases", 0),
      "population" => Map.get(tick.inputs, "population", 0),
      "settlement" => stringify(settlement)
    }

    case ParticipantState.put(study_id, subject, @state_uri, state) do
      {:ok, _} ->
        :ok

      {:error, :no_such_participant} ->
        :ok

      # Settling a day and failing to tell the participant is worse than not settling it. Rolling
      # back means the next run retries and fails the same way, which is the right noise for a bug
      # in what the study publishes.
      {:error, {:invalid_state, error}} ->
        Repo.rollback({:invalid_state, subject, error})
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
