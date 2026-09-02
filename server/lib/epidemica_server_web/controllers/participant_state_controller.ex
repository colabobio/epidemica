defmodule EpidemicaServerWeb.ParticipantStateController do
  @moduledoc """
  Serves a participant their own state.

  Scoped entirely by the bearer token: there is no path parameter naming a participant, so one
  device cannot ask about another's state even by guessing.
  """

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.ParticipantState
  alias EpidemicaServerWeb.Problem

  def show(conn, _params) do
    auth = conn.assigns.auth

    case ParticipantState.fetch(auth.study_id, auth.subject) do
      {:ok, document} ->
        json(conn, document)

      {:error, :not_found} ->
        # Nothing has been computed yet. A synthesised empty document would be simpler for the
        # client and worse for everyone: it would have to be valid against a study's own state
        # contract, which the server cannot construct without knowing what that study means.
        Problem.send(
          conn,
          404,
          "no_state_yet",
          "No state has been computed for this participant yet."
        )
    end
  end
end
