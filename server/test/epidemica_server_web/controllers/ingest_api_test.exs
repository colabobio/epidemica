defmodule EpidemicaServerWeb.IngestApiTest do
  @moduledoc """
  End-to-end conformance against `contracts/api/ingest/v1.yaml`.

  The request bodies are the contract fixtures themselves, so the API and the contracts cannot drift
  apart without a test failing.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, Studies}

  @contracts_dir Path.expand("../../../../contracts", __DIR__)
  @subject "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6"
  @device_id "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"
  @protocol_hash "sha256:9f2b7c1d4e6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c"

  setup %{conn: conn} do
    {:ok, study} =
      Studies.create_study(%{
        name: "Contact logging pilot",
        protocol_hash: @protocol_hash,
        protocol: %{"modules" => %{"proximity" => %{}}}
      })

    {:ok, _} = Studies.add_join_code(study, "CONTACT-1")

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "CONTACT-1",
        "subject" => @subject,
        "device_id" => @device_id,
        "platform" => "ios"
      })

    conn = put_req_header(conn, "content-type", "application/json")
    {:ok, conn: conn, study: study, enrolled: enrolled}
  end

  defp authed(conn, %{access_token: token}),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp envelope_fixtures(kind) do
    @contracts_dir
    |> Path.join("fixtures/observations/envelope/#{kind}.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(& &1["instance"])
  end

  # Fixtures illustrate a schema and reuse the same seq; in a batch seq is the idempotency key.
  # They also carry their own study_id, which must be rewritten to the study we enrolled in.
  defp for_study(envelopes, study_id) do
    envelopes
    |> Enum.with_index()
    |> Enum.map(fn
      {envelope, i} when is_map(envelope) ->
        Map.merge(envelope, %{"seq" => i, "study_id" => study_id, "subject" => @subject})

      {other, _} ->
        other
    end)
  end

  describe "POST /v1/observations" do
    test "accepts the valid fixtures", %{conn: conn, study: study, enrolled: e} do
      body = %{"observations" => for_study(envelope_fixtures("valid"), study.id)}

      response =
        conn |> authed(e) |> post("/v1/observations", body) |> json_response(200)

      assert response["received"] == length(body["observations"])
      assert response["rejected"] == 0
      assert response["server_time"]
    end

    test "stores rather than loses the invalid fixtures, and never 500s", %{
      conn: conn,
      study: study,
      enrolled: e
    } do
      body = %{"observations" => for_study(envelope_fixtures("invalid"), study.id)}

      response = conn |> authed(e) |> post("/v1/observations", body) |> json_response(200)

      assert response["accepted"] == 0
      assert response["quarantined"] + response["rejected"] == length(body["observations"])
      assert Enum.all?(response["exceptions"], &(&1["status"] in ~w(quarantined rejected)))
    end

    test "reports duplicates on a resend", %{conn: conn, study: study, enrolled: e} do
      body = %{"observations" => for_study(envelope_fixtures("valid"), study.id)}

      conn |> authed(e) |> post("/v1/observations", body) |> json_response(200)
      again = build_conn() |> authed(e) |> post("/v1/observations", body) |> json_response(200)

      assert again["duplicate"] == length(body["observations"])
      assert again["accepted"] == 0
    end

    test "accepts a gzipped body", %{conn: conn, study: study, enrolled: e} do
      body = %{"observations" => for_study(envelope_fixtures("valid"), study.id)}
      gzipped = body |> Jason.encode!() |> :zlib.gzip()

      response =
        conn
        |> authed(e)
        |> put_req_header("content-encoding", "gzip")
        |> post("/v1/observations", gzipped)
        |> json_response(200)

      assert response["received"] == length(body["observations"])
    end

    test "refuses a batch whose device disagrees with the token", %{
      conn: conn,
      study: study,
      enrolled: e
    } do
      [envelope] = envelope_fixtures("valid") |> Enum.take(1) |> for_study(study.id)
      envelope = Map.put(envelope, "device_id", "99999999-9999-4999-8999-999999999999")

      conn
      |> authed(e)
      |> post("/v1/observations", %{"observations" => [envelope]})
      |> json_response(403)
    end

    test "refuses a batch whose subject disagrees with the token", %{
      conn: conn,
      study: study,
      enrolled: e
    } do
      [envelope] = envelope_fixtures("valid") |> Enum.take(1) |> for_study(study.id)
      envelope = Map.put(envelope, "subject", "someone-elses-pseudonym")

      conn
      |> authed(e)
      |> post("/v1/observations", %{"observations" => [envelope]})
      |> json_response(403)
    end

    test "requires a token", %{conn: conn, study: study} do
      body = %{"observations" => for_study(envelope_fixtures("valid"), study.id)}
      assert conn |> post("/v1/observations", body) |> json_response(401)
    end

    test "rejects a malformed request body", %{conn: conn, enrolled: e} do
      assert conn |> authed(e) |> post("/v1/observations", %{"nope" => []}) |> json_response(400)
    end
  end

  describe "GET /v1/observations/ack" do
    test "reports the contiguous watermark", %{conn: conn, study: study, enrolled: e} do
      [a, b, _c, d] = for_study(envelope_fixtures("valid"), study.id)

      conn
      |> authed(e)
      |> post("/v1/observations", %{"observations" => [a, b, d]})
      |> json_response(200)

      mark = build_conn() |> authed(e) |> get("/v1/observations/ack") |> json_response(200)

      assert mark["highest_seq"] == 3
      assert mark["highest_contiguous_seq"] == 1
      assert mark["device_id"] == @device_id
    end
  end

  describe "enrollment" do
    test "returns tokens and the protocol to configure from", %{conn: conn} do
      body = %{
        "join_code" => "contact-1",
        "subject" => "another-participant-pseudonym",
        "device_id" => "22222222-2222-4222-8222-222222222222",
        "platform" => "android"
      }

      response = conn |> post("/v1/enrollments", body) |> json_response(201)

      assert response["access_token"]
      assert response["refresh_token"]
      assert response["token_type"] == "Bearer"
      assert response["protocol_hash"] == @protocol_hash

      # Anything a study schedules from joining rather than from its own start is measured against
      # this, so it has to arrive with the enrolment rather than be inferred from the device clock.
      assert {:ok, _, _} = DateTime.from_iso8601(response["enrolled_at"])
    end

    test "the moment of joining does not move when a device re-enrols", %{conn: conn} do
      body = %{
        "join_code" => "contact-1",
        "subject" => "a-returning-participant-x",
        "device_id" => "44444444-4444-4444-8444-444444444444",
        "platform" => "android"
      }

      first = conn |> post("/v1/enrollments", body) |> json_response(201)
      again = conn |> post("/v1/enrollments", body) |> json_response(201)

      # A reinstall must not reopen a question that is asked once, a fixed time after joining.
      assert again["enrolled_at"] == first["enrolled_at"]
    end

    test "an unknown code is a 404 indistinguishable from a closed study", %{conn: conn} do
      body = %{
        "join_code" => "NOPE",
        "subject" => "another-participant-pseudonym",
        "device_id" => "33333333-3333-4333-8333-333333333333",
        "platform" => "ios"
      }

      conn |> post("/v1/enrollments", body) |> json_response(404)
    end

    test "a refresh token can be exchanged, and is rotated", %{conn: conn, enrolled: e} do
      body = %{"grant_type" => "refresh_token", "refresh_token" => e.refresh_token}
      first = conn |> post("/v1/tokens", body) |> json_response(200)

      assert first["access_token"] != e.access_token
      assert first["refresh_token"] != e.refresh_token

      # The old refresh token is revoked, so a replay fails.
      build_conn() |> post("/v1/tokens", body) |> json_response(401)
    end

    test "a rotated-away access token stops working", %{conn: conn, study: study, enrolled: e} do
      conn
      |> post("/v1/tokens", %{"grant_type" => "refresh_token", "refresh_token" => e.refresh_token})
      |> json_response(200)

      body = %{"observations" => for_study(envelope_fixtures("valid"), study.id)}
      build_conn() |> authed(e) |> post("/v1/observations", body) |> json_response(401)
    end
  end

  describe "GET /v1/health" do
    test "reports the envelope versions this build can validate", %{conn: conn} do
      response = conn |> get("/v1/health") |> json_response(200)

      assert response["status"] == "ok"
      assert "1.0" in response["envelope_versions"]
      assert response["server_time"]
    end
  end
end
