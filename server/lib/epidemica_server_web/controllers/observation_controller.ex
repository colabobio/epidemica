defmodule EpidemicaServerWeb.ObservationController do
  @moduledoc "Batch ingest and the delivery watermark. Implements `contracts/api/ingest/v1.yaml`."

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.Ingest
  alias EpidemicaServerWeb.Problem

  def create(conn, %{"observations" => observations}) when is_list(observations) do
    case Ingest.submit(conn.assigns.auth, observations) do
      {:ok, result} ->
        json(conn, result)

      {:error, :forbidden} ->
        Problem.send(conn, 403, "Forbidden", "This batch does not match the token's binding.")

      {:error, :heterogeneous_batch} ->
        Problem.send(
          conn,
          400,
          "Bad Request",
          "All observations in a batch must share device_id, study_id and subject."
        )

      {:error, :too_large} ->
        Problem.send(conn, 400, "Bad Request", "A batch may contain at most 1000 observations.")

      {:error, :empty} ->
        Problem.send(conn, 400, "Bad Request", "A batch must contain at least one observation.")
    end
  end

  def create(conn, _params) do
    Problem.send(conn, 400, "Bad Request", "Expected an object with an 'observations' array.")
  end

  def ack(conn, _params) do
    json(conn, Ingest.watermark(conn.assigns.auth))
  end
end
