defmodule EpidemicaServerWeb.GameActionController do
  @moduledoc """
  Records a participant's game decisions.

  Scoped entirely by the bearer token, like every other participant route: a device can only act
  for itself. The decision is recorded with the time the server received it rather than a time the
  client supplies, because protection costs points and changes transmission — a participant who
  could name their own effective time could protect themselves retrospectively.
  """

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.Epigame
  alias EpidemicaServerWeb.Problem

  def create(conn, %{"action" => "protect"}) do
    auth = conn.assigns.auth
    :ok = Epigame.protect(auth.study_id, auth.subject, DateTime.utc_now(), pars_for(auth))

    json(conn, %{"action" => "protect", "accepted" => true})
  end

  def create(conn, %{"action" => "release"}) do
    auth = conn.assigns.auth

    case Epigame.release(auth.study_id, auth.subject) do
      :ok ->
        json(conn, %{"action" => "release", "accepted" => true})

      {:error, :not_protected} ->
        Problem.send(conn, 409, "not_protected", "This participant is not currently protected.")
    end
  end

  def create(conn, _params) do
    Problem.send(conn, 400, "unknown_action", "Expected an `action` of `protect` or `release`.")
  end

  defp pars_for(auth) do
    case EpidemicaServer.Studies.get_study(auth.study_id) do
      %{protocol: %{"rules" => %{"pars" => pars}}} -> pars
      _ -> %{}
    end
  end
end
