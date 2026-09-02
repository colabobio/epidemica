defmodule EpidemicaServer.Health do
  @moduledoc """
  How much of a period each participant's device was actually observing.

  A model that infers exposure from an absence of contacts needs this. Without it, a phone with
  Bluetooth off is indistinguishable from a participant who met nobody, and the model would read no
  observation as no exposure — the most consequential kind of quiet error a study can have.

  Coverage is asserted positively by `module_status` observations. Anything not covered is
  **unobserved**, not quiet.
  """

  import Ecto.Query

  alias EpidemicaServer.Ingest.Observation
  alias EpidemicaServer.Repo

  @status_uri "https://schemas.epidemica.info/observations/health/module_status/1.0.0.json"

  @doc """
  Fraction of `[from, to)` each participant's named module was sensing for, keyed by subject.

  Participants with no reports at all are absent from the map rather than present with zero, so a
  caller can tell "never heard from" from "heard from, and it was off".
  """
  def coverage(study_id, module, from, to) do
    window = DateTime.diff(to, from, :microsecond)

    study_id
    |> sensing_windows(module, from, to)
    |> Enum.group_by(fn {subject, _, _} -> subject end, fn {_, s, e} -> {s, e} end)
    |> Map.new(fn {subject, intervals} ->
      {subject, covered_microseconds(intervals) / window}
    end)
  end

  @doc """
  Subjects whose coverage of the period falls below `threshold`.

  These are the participants a transmission model must not treat as observed. Everyone enrolled but
  never heard from is included, which is the case that matters most: a device that never reported
  is exactly the one a naive query would miss.
  """
  def insufficiently_observed(study_id, module, from, to, threshold, enrolled_subjects) do
    covered = coverage(study_id, module, from, to)

    enrolled_subjects
    |> Enum.filter(fn subject -> Map.get(covered, subject, 0.0) < threshold end)
    |> Enum.sort()
  end

  defp sensing_windows(study_id, module, from, to) do
    query =
      from o in Observation,
        where:
          o.study_id == ^study_id and o.module == ^module and o.schema_uri == @status_uri and
            fragment("?->>'state'", o.payload) == "sensing",
        select: {
          o.subject,
          fragment("?->>'window_start'", o.payload),
          fragment("?->>'window_end'", o.payload)
        }

    query
    |> Repo.all()
    |> Enum.flat_map(fn {subject, start_s, end_s} ->
      with {:ok, s, _} <- DateTime.from_iso8601(start_s),
           {:ok, e, _} <- DateTime.from_iso8601(end_s),
           clipped_start = max_datetime(s, from),
           clipped_end = min_datetime(e, to),
           true <- DateTime.compare(clipped_start, clipped_end) == :lt do
        [{subject, clipped_start, clipped_end}]
      else
        # An unparseable or non-overlapping window asserts nothing. Discarding it is safe in the
        # direction that matters: it can only reduce claimed coverage.
        _ -> []
      end
    end)
  end

  # Overlapping and duplicate reports are normal -- a retried batch delivers the same window twice.
  # Summing raw durations would let a device claim more coverage than the period contains.
  defp covered_microseconds(intervals) do
    intervals
    |> Enum.sort_by(fn {s, _} -> DateTime.to_unix(s, :microsecond) end)
    |> Enum.reduce({0, nil}, fn {s, e}, {total, current} ->
      case current do
        nil ->
          {total, {s, e}}

        {cs, ce} ->
          if DateTime.compare(s, ce) != :gt do
            {total, {cs, max_datetime(ce, e)}}
          else
            {total + DateTime.diff(ce, cs, :microsecond), {s, e}}
          end
      end
    end)
    |> then(fn
      {total, nil} -> total
      {total, {cs, ce}} -> total + DateTime.diff(ce, cs, :microsecond)
    end)
  end

  defp max_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
