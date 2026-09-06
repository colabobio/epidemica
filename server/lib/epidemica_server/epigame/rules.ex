defmodule EpidemicaServer.Epigame.Rules do
  @moduledoc """
  The scoring rules, as pure functions.

  Points are a function of state the participant was already shown — never of state revealed by the
  tick that closes the day. A player told they were healthy earns that day's points even if the tick
  then infects them; the infection announces itself tomorrow. Nobody is retroactively docked.

  Nothing here touches the database or the clock, because the app computes the same function for
  immediate feedback and the two must agree. `contracts/game/epigame_rules/1.0.0.vectors.json` is
  the shared evidence that they do.
  """

  @defaults %{
    "healthy_points" => 2,
    "infected_points" => 0,
    "protection_cost" => 1,
    "contact_points" => 5,
    "contact_min_seconds" => 600,
    "contact_cooldown_days" => 1,
    "contact_points_while_infected" => false,
    "protection_window_seconds" => 86_400,
    "carry_over_days" => 3
  }

  @doc "Rule constants, bundle values over defaults. Every number the game uses passes through here."
  def pars(rules_block) when is_map(rules_block) do
    Map.merge(@defaults, Map.get(rules_block, "pars") || %{})
  end

  def pars(_), do: @defaults

  @doc """
  The constants one participant plays by: defaults, then the study's `pars`, then their arm's.

  One function on purpose. Every caller that asks "what are the rules" asks it here, so a caller
  cannot compute them for the wrong group, and the answer a participant is scored by and the answer
  their app shows are the same overlay.
  """
  def pars_for(rules_block, arm) when is_map(rules_block) do
    arm_pars =
      case arm do
        nil ->
          %{}

        name when is_binary(name) ->
          rules_block
          |> Map.get("arms", [])
          |> Enum.find_value(%{}, fn a -> if a["name"] == name, do: a["pars"] || %{} end)
      end

    Map.merge(pars(rules_block), arm_pars)
  end

  def pars_for(_rules_block, _arm), do: @defaults

  @doc """
  The arms a study declares, as `[{name, weight}]`, or nil for one that does not.

  Nil rather than an empty list so "no randomisation" and "an empty arms array" stay distinct: the
  first is an ordinary study, the second is a bundle that asks for a draw with nothing to draw.
  """
  def arms(rules_block) when is_map(rules_block) do
    case Map.get(rules_block, "arms") do
      list when is_list(list) ->
        choices =
          Enum.map(list, fn arm -> {Map.fetch!(arm, "name"), Map.fetch!(arm, "weight")} end)

        # A duplicate name merges two conditions into one, which is exactly the split the arm
        # exists to make. Rejected here because JSON Schema cannot say it.
        names = Enum.map(choices, &elem(&1, 0))

        if Enum.uniq(names) != names do
          duplicates = names -- Enum.uniq(names)
          raise ArgumentError, "two arms share a name: #{inspect(duplicates)}"
        end

        choices

      _ ->
        nil
    end
  end

  def arms(_), do: nil

  @doc """
  Which arm a new enrollment lands in, drawn by weight.

  Weighted rather than blocked on purpose. Blocking balances small groups but makes the assignment
  depend on join order, which two phones joining at once can disagree about. A weighted draw is
  independent per participant, and imbalance at small numbers is the price of not having to
  coordinate. Reproducible for a given study and subject, so an audit can re-derive the split.
  """
  def assign_arm(rules_block, study_id, subject) do
    case arms(rules_block) do
      nil ->
        nil

      [] ->
        nil

      choices ->
        total = Enum.sum(Enum.map(choices, fn {_name, weight} -> weight end))
        draw = :erlang.phash2({study_id, subject}, total)

        choices
        |> Enum.reduce_while(0, fn {name, weight}, acc ->
          if draw < acc + weight, do: {:halt, {:found, name}}, else: {:cont, acc + weight}
        end)
        |> case do
          {:found, name} -> name
          _ -> nil
        end
    end
  end

  @doc """
  Settle one participant-day.

  `facts` carries only what the participant could have known: the state they were shown, whether
  their device was being heard from, whether they chose protection, and which contacts cleared.
  """
  def settle(pars, facts) do
    opening = Map.fetch!(facts, :opening)
    lines = lines(pars, facts)
    closing = opening + Enum.sum(Enum.map(lines, & &1.points))

    %{
      day: Map.fetch!(facts, :day),
      opening: opening,
      closing: closing,
      lines: lines
    }
  end

  # A day the study could not observe is not scored, and not penalised either. Charging for it would
  # correlate the score with the participant's phone; making it free would make going dark the
  # dominant strategy and the study would collect nothing.
  defp lines(_pars, %{observed: false}), do: [%{reason: "not_sensing", points: 0}]

  defp lines(pars, facts) do
    infected = facts.epi_state == "infected"

    daily =
      if infected,
        do: %{reason: "infected", points: pars["infected_points"]},
        else: %{reason: "healthy", points: pars["healthy_points"]}

    [daily]
    |> add_protection(pars, facts)
    |> add_contacts(pars, facts, infected)
  end

  defp add_protection(lines, pars, %{protection: "chosen"}) do
    lines ++ [%{reason: "protection", points: -pars["protection_cost"]}]
  end

  defp add_protection(lines, _pars, _facts), do: lines

  defp add_contacts(lines, pars, facts, infected) do
    if infected and not pars["contact_points_while_infected"] do
      lines
    else
      lines
      |> contact_line(pars, "contacts", Map.get(facts, :contacts, 0))
      |> contact_line(pars, "carried_over", Map.get(facts, :carried_over, 0))
    end
  end

  defp contact_line(lines, _pars, _reason, 0), do: lines

  defp contact_line(lines, pars, reason, count) do
    lines ++ [%{reason: reason, points: pars["contact_points"] * count, count: count}]
  end

  @doc """
  Which of a day's reconciled pairs earn points, and for whom.

  A contact must be long enough, must join two participants who were both unprotected, and must not
  repeat an award the pair has already had inside the cooldown. Protection removes the reward as
  well as the risk — that is the trade-off the study is there to measure.
  """
  def award_contacts(pars, network, protected, previously_awarded) do
    network
    |> Enum.filter(&qualifies?(&1, pars, protected, previously_awarded))
    |> Enum.map(& &1.pair)
  end

  defp qualifies?(edge, pars, protected, previously_awarded) do
    {a, b} = edge.pair

    edge.seconds >= pars["contact_min_seconds"] and
      not MapSet.member?(protected, a) and
      not MapSet.member?(protected, b) and
      not MapSet.member?(previously_awarded, edge.pair)
  end

  @doc "Pairs still inside their cooldown on `day`, given the days each pair was last awarded."
  def in_cooldown(pars, awards, day) do
    cooldown = pars["contact_cooldown_days"]

    for {pair, last_day} <- awards, day - last_day <= cooldown, into: MapSet.new() do
      pair
    end
  end
end
