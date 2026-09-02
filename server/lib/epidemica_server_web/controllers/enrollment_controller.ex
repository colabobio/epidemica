defmodule EpidemicaServerWeb.EnrollmentController do
  @moduledoc "Joining a study, and exchanging a refresh token."

  use EpidemicaServerWeb, :controller

  alias EpidemicaServer.{Contracts, Enrollment}
  alias EpidemicaServerWeb.Problem

  def create(conn, params) do
    case Enrollment.enroll(params) do
      {:ok, result} ->
        conn |> put_status(201) |> json(result)

      # A closed study is reported the same way as a missing one, so join codes cannot be
      # enumerated by comparing responses.
      {:error, reason} when reason in [:no_such_study, :study_closed] ->
        Problem.send(conn, 404, "Not Found", "No open study matches that join code.")

      {:error, :device_claimed} ->
        Problem.send(
          conn,
          409,
          "Conflict",
          "This device is already enrolled in this study under a different pseudonym."
        )

      {:error, :invalid_request} ->
        Problem.send(conn, 400, "Bad Request", "join_code, subject and device_id are required.")

      {:error, %Ecto.Changeset{} = changeset} ->
        Problem.send(conn, 400, "Bad Request", changeset_detail(changeset))
    end
  end

  def refresh(conn, %{"grant_type" => "refresh_token", "refresh_token" => token}) do
    case Enrollment.refresh(token) do
      {:ok, result} ->
        json(conn, result)

      {:error, _reason} ->
        Problem.send(conn, 401, "Unauthorized", "The refresh token is not valid; re-enroll.")
    end
  end

  def refresh(conn, _params) do
    Problem.send(conn, 400, "Bad Request", "grant_type must be 'refresh_token'.")
  end

  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      version: Application.spec(:epidemica_server, :vsn) |> to_string(),
      envelope_versions: Contracts.envelope_versions(),
      server_time: DateTime.utc_now()
    })
  end

  defp changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
