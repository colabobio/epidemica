defmodule EpidemicaServerWeb.Plugs.ParticipantToken do
  @moduledoc """
  Resolves a bearer token into the device and study it authorises.

  Everything downstream reads identity from `conn.assigns.auth` rather than from the request body,
  so a client cannot assert who it is.
  """

  import Plug.Conn

  alias EpidemicaServer.Enrollment
  alias EpidemicaServerWeb.Problem

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, auth} <- Enrollment.authenticate(token) do
      assign(conn, :auth, auth)
    else
      {:error, reason} ->
        conn
        |> Problem.send(401, "Unauthorized", detail(reason))
        |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, :missing}
    end
  end

  defp detail(:missing), do: "A bearer token is required."
  defp detail(:expired), do: "The access token has expired; refresh it and retry once."
  defp detail(:revoked), do: "This token has been revoked."
  defp detail(:withdrawn), do: "This participant has withdrawn from the study."
  defp detail(_), do: "The access token is not valid."
end
