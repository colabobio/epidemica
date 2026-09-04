defmodule EpidemicaServerWeb.InstrumentController do
  @moduledoc """
  Serves an instrument definition.

  Scoped to the token's own study, and there is no path parameter naming one: a device can only
  read the questions of the study it joined. The body is the exact bytes registered, because the
  device compares their digest against what the bundle pinned and a re-encoding would not match.
  """

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.Instruments
  alias EpidemicaServerWeb.Problem

  def show(conn, %{"instrument_id" => instrument_id, "version" => version}) do
    case Instruments.fetch_source(conn.assigns.auth.study_id, instrument_id, version) do
      {:ok, source} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, source)

      {:error, :not_found} ->
        Problem.send(
          conn,
          404,
          "no_such_instrument",
          "This study has no #{instrument_id} at version #{version}."
        )
    end
  end
end
