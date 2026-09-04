defmodule EpidemicaServerWeb.GameActionController do
  @moduledoc """
  Records a participant's game decisions.

  Scoped entirely by the bearer token, like every other participant route: a device can only act
  for itself. The decision is recorded with the time the server received it rather than a time the
  client supplies, because protection costs points and changes transmission — a participant who
  could name their own effective time could protect themselves retrospectively.
  """

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.{Epigame, Studies}
  alias EpidemicaServerWeb.Problem

  def create(conn, %{"action" => "protect"}) do
    auth = conn.assigns.auth

    with {:ok, study} <- running_study(auth.study_id) do
      {:ok, until} =
        Epigame.protect(auth.study_id, auth.subject, DateTime.utc_now(), pars_for(study))

      json(conn, %{
        "action" => "protect",
        "accepted" => true,
        "protected_until" => until && DateTime.to_iso8601(until)
      })
    else
      {:error, :not_running} -> not_running(conn)
    end
  end

  def create(conn, %{"action" => "release"}) do
    auth = conn.assigns.auth

    with {:ok, _study} <- running_study(auth.study_id) do
      case Epigame.release(auth.study_id, auth.subject) do
        :ok ->
          json(conn, %{"action" => "release", "accepted" => true, "protected_until" => nil})

        {:error, :not_protected} ->
          Problem.send(conn, 409, "not_protected", "This participant is not currently protected.")
      end
    else
      {:error, :not_running} -> not_running(conn)
    end
  end

  def create(conn, _params) do
    Problem.send(conn, 400, "unknown_action", "Expected an `action` of `protect` or `release`.")
  end

  # A decision taken before the study opens or after it closes would be charged for on a day that
  # will never be settled, so it is refused rather than recorded and quietly ignored.
  defp running_study(study_id) do
    case Studies.get_study(study_id) do
      nil -> {:error, :not_running}
      study -> if Studies.running?(study), do: {:ok, study}, else: {:error, :not_running}
    end
  end

  defp not_running(conn) do
    Problem.send(conn, 409, "study_not_running", "This study is not running right now.")
  end

  defp pars_for(%{protocol: %{"rules" => %{"pars" => pars}}}), do: pars
  defp pars_for(_study), do: %{}
end
