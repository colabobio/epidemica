defmodule EpidemicaServerWeb.Problem do
  @moduledoc "RFC 9457 problem details, the error shape the ingest contract specifies."

  import Plug.Conn

  def send(conn, status, title, detail \\ nil) do
    body =
      %{type: "about:blank", title: title, status: status}
      |> maybe_put(:detail, detail)
      |> maybe_put(:instance, conn.request_path)
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, body)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
