defmodule EpidemicaServer.Reconciliation do
  @moduledoc """
  The contact network, reconciled from both sides.

  A sees B for twelve minutes and B sees A for seven, because detection is asymmetric. A model
  needs one number, and choosing it is the most consequential decision in the pipeline.

  **Contact happened when either side saw it.** Intervals are unioned, never summed or intersected:
  summing double-counts the period both devices observed, and intersecting discards real contact
  every time one phone was asleep.

  **Distance comes from the better-observed side, unmodified.** The union says how long contact
  lasted; the side that watched more of it says how close. Scaling that side's distribution up to
  the unioned duration was considered and rejected — it would assert distance information for a
  period no device measured. As a result `band_seconds` may sum to less than `seconds`, which is
  not a defect: it is the honest statement that we know contact occurred for longer than we know
  how close it was.

  One-sided reports are kept and flagged. A study that later wants to be strict can filter on the
  flag; a study that discarded them cannot get them back.
  """

  import Ecto.Query

  alias EpidemicaServer.Ingest.Observation
  alias EpidemicaServer.Repo

  @bands ~w(immediate close medium far)

  @doc """
  The reconciled network for a period, as a list of pairs.

  Pass `received_before:` to compute the network as it stood at a point in time. A simulation tick
  uses this so that observations arriving late enter the record without rewriting a day whose
  consequences participants have already been told about.
  """
  def network(study_id, from, to, opts \\ []) do
    study_id
    |> episodes(from, to, Keyword.get(opts, :received_before))
    |> Enum.group_by(&pair_of/1)
    |> Enum.map(fn {pair, episodes} -> reconcile(pair, episodes) end)
    |> Enum.sort_by(& &1.pair)
  end

  # Sorted, so both devices' reports of one encounter land in the same group and the result does
  # not depend on which of them uploaded first.
  defp pair_of(%{subject: subject, peer: peer}) do
    if subject <= peer, do: {subject, peer}, else: {peer, subject}
  end

  defp reconcile({a, b}, episodes) do
    by_reporter = Enum.group_by(episodes, & &1.subject)

    # Deterministic under a tie: the same observations must always produce the same network.
    {chosen_reporter, chosen} =
      by_reporter
      |> Enum.map(fn {reporter, eps} -> {reporter, eps, observed_total(eps)} end)
      |> Enum.sort_by(fn {reporter, _, observed} -> {-observed, reporter} end)
      |> hd()
      |> then(fn {reporter, eps, _} -> {reporter, eps} end)

    %{
      pair: {a, b},
      seconds: union_seconds(episodes),
      observed_seconds: observed_total(chosen),
      band_seconds: sum_bands(chosen),
      reported_by: chosen_reporter,
      both_reported: map_size(by_reporter) == 2,
      episode_count: length(episodes)
    }
  end

  defp observed_total(episodes) do
    Enum.reduce(episodes, 0.0, fn e, acc -> acc + (e.observed_seconds || 0.0) end)
  end

  defp sum_bands(episodes) do
    Map.new(@bands, fn band ->
      {band,
       Enum.reduce(episodes, 0.0, fn e, acc ->
         acc + ((e.band_seconds || %{}) |> Map.get(band, 0) |> to_float())
       end)}
    end)
  end

  defp to_float(v) when is_number(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp union_seconds(episodes) do
    episodes
    |> Enum.map(&{&1.started_at, &1.ended_at})
    |> Enum.sort_by(fn {s, _} -> DateTime.to_unix(s, :microsecond) end)
    |> Enum.reduce({0, nil}, fn {s, e}, {total, current} ->
      case current do
        nil ->
          {total, {s, e}}

        {cs, ce} ->
          if DateTime.compare(s, ce) != :gt do
            {total, {cs, if(DateTime.compare(ce, e) == :gt, do: ce, else: e)}}
          else
            {total + DateTime.diff(ce, cs, :microsecond), {s, e}}
          end
      end
    end)
    |> then(fn
      {total, nil} -> total / 1_000_000
      {total, {cs, ce}} -> (total + DateTime.diff(ce, cs, :microsecond)) / 1_000_000
    end)
  end

  defp episodes(study_id, from, to, received_before) do
    query =
      from c in "contacts",
        join: o in Observation,
        on: o.id == c.observation_id,
        where:
          c.study_id == type(^study_id, :binary_id) and c.started_at < ^to and c.ended_at >= ^from,
        select: %{
          subject: c.subject,
          peer: c.peer,
          started_at: c.started_at,
          ended_at: c.ended_at,
          observed_seconds: c.observed_seconds,
          band_seconds: c.band_seconds,
          received_at: o.received_at
        }

    query =
      if received_before,
        do: where(query, [c, o], o.received_at < ^received_before),
        else: query

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{row | started_at: to_utc(row.started_at), ended_at: to_utc(row.ended_at)}
    end)
  end

  # A schemaless query has no schema to say these columns are UTC, so they arrive naive.
  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
end
