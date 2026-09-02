defmodule EpidemicaServerWeb.ProtocolController do
  @moduledoc """
  Serves a study's protocol bundle.

  The response body is the exact bytes registered for the study, never a re-encoding: the client
  hashes what it receives and compares it against what enrollment promised, and a document that
  round-trips through a decoder can come back with different key order and a different hash.
  """

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.Studies
  alias EpidemicaServerWeb.Problem

  def show(conn, %{"id" => id}) do
    # Scoped to the token's own study. A bundle can carry the study's join code, so letting one
    # study's device read another's would hand out the means to enrol in it.
    if conn.assigns.auth.study_id != id do
      Problem.send(conn, 403, "forbidden", "This token is not enrolled in that study.")
    else
      case Studies.fetch_protocol_source(id) do
        {:ok, nil} ->
          Problem.send(conn, 404, "no_protocol", "That study has no protocol bundle registered.")

        {:ok, source} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, source)

        {:error, :not_found} ->
          Problem.send(conn, 404, "no_such_study", "No such study.")
      end
    end
  end
end
