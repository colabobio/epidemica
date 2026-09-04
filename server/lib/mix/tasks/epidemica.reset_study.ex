defmodule Mix.Tasks.Epidemica.ResetStudy do
  @shortdoc "Clear a study's simulated and scored state, keeping its observations"

  @moduledoc """
  Forget everything a study *decided*, keep everything it *observed*.

      mix epidemica.reset_study --study <uuid>
      mix epidemica.reset_study --study <uuid> --yes
      mix epidemica.reset_study --study <uuid> --clear-actions

  A tick is immutable, which is right for a running study and hostile to debugging: one wrong day
  is permanent, and recovering means hand-written SQL across five tables. This task exists so that
  a development study can be replayed — collect real contact data once, then run the whole arc as
  many times as you like against byte-identical input while tuning parameters.

  Removed: twin ticks and agents, the game ledger, contact awards, and published participant state.

  Kept: observations, the contacts projection, participants, devices, tokens, join codes, and
  **protection actions**. A participant tapping *Protect me* is something they did, not something
  the study decided — input, like an observation. Keeping it is what makes a replay reproduce the
  same scores rather than a different game. `--clear-actions` drops them too, for when the point is
  to exercise the protection flow again from nothing.

  **Not for production.** Participants have been shown the scores this deletes.
  """

  use Mix.Task

  import Ecto.Query

  alias EpidemicaServer.{Repo, Studies}

  @requirements ["app.start"]

  # Order matters only for readability; none of these reference each other.
  @derived ~w(participant_states game_ledger game_contact_awards twin_ticks twin_agents)
  @input ~w(game_actions)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [study: :string, yes: :boolean, clear_actions: :boolean])

    study_id = opts[:study] || Mix.raise("--study <uuid> is required")

    study =
      case Studies.get_study(study_id) do
        nil -> Mix.raise("no study #{study_id}")
        study -> study
      end

    # `or` demands a boolean on its left and OptionParser gives nil for an absent flag.
    if Keyword.get(opts, :yes, false) or confirm(study) do
      reset(study, study_id, Keyword.get(opts, :clear_actions, false))
    else
      Mix.shell().info("Nothing was changed.")
    end
  end

  defp reset(study, study_id, clear_actions?) do
    tables = if clear_actions?, do: @derived ++ @input, else: @derived
    counts = Enum.map(tables, fn table -> {table, delete_from(table, study_id)} end)

    Enum.each(counts, fn {table, count} -> Mix.shell().info("  #{table}: #{count} removed") end)

    unless clear_actions? do
      Mix.shell().info("  game_actions: #{count_in("game_actions", study_id)} kept")
    end

    Mix.shell().info("""

    #{study.name} is back to the state it was in before its first tick.
    Observations were not touched: #{count_in("observations", study_id)} kept.

    Tick it again with:

      mix epidemica.tick --study #{study_id} --catch-up
    """)
  end

  # Defaults to no: a stray Enter should not delete scores participants have already been shown.
  defp confirm(study) do
    Mix.shell().yes?("Delete all simulated and scored state for #{study.name}?", default: :no)
  end

  defp delete_from(table, study_id) do
    {count, _} =
      Repo.delete_all(from r in table, where: r.study_id == type(^study_id, :binary_id))

    count
  end

  defp count_in(table, study_id) do
    Repo.one(
      from r in table,
        where: r.study_id == type(^study_id, :binary_id),
        select: count()
    )
  end
end
