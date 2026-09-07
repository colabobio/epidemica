defmodule EpidemicaServerWeb.ProtocolApiTest do
  @moduledoc """
  Serving a study's protocol bundle.

  The client hashes the bytes it receives and refuses the study if they do not match what
  enrollment promised, so "byte-identical" is a contract here rather than an implementation detail.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, Studies}
  alias EpidemicaServer.Studies.Study

  @bundle_path Path.expand("../../../../studies/contactlog/bundle.json", __DIR__)

  setup %{conn: conn} do
    source = File.read!(@bundle_path)
    {:ok, study} = Studies.create_study_from_bundle("Contact logging pilot", source)
    {:ok, _} = Studies.add_join_code(study, "CONTACT-1")

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "CONTACT-1",
        "subject" => "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6",
        "device_id" => "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
        "platform" => "android"
      })

    {:ok, conn: conn, study: study, source: source, enrolled: enrolled}
  end

  # A second study to hold a token that must not work here. Minimal, but a real bundle: registration
  # validates, so a placeholder that is not one would fail for the wrong reason.
  defp other_bundle(title) do
    Jason.encode!(%{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "title" => title,
      "modules" => %{"proximity" => %{}}
    })
  end

  defp authed(conn, %{access_token: token}),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "serves the exact bytes that were registered", ctx do
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/studies/#{ctx.study.id}/protocol")

    assert response(conn, 200) == ctx.source
    assert response_content_type(conn, :json)
  end

  test "the served bytes hash to what enrollment promised", ctx do
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/studies/#{ctx.study.id}/protocol")

    assert Study.hash_of(response(conn, 200)) == ctx.enrolled.protocol_hash
  end

  test "enrollment points at an absolute URL a device can actually fetch", ctx do
    assert ctx.enrolled.protocol_url =~ ~r{^https?://}
    assert String.ends_with?(ctx.enrolled.protocol_url, "/v1/studies/#{ctx.study.id}/protocol")
  end

  test "a token from another study cannot read this bundle", ctx do
    {:ok, other} = Studies.create_study_from_bundle("Other study", other_bundle("Other study"))
    {:ok, _} = Studies.add_join_code(other, "OTHER-1")

    {:ok, outsider} =
      Enrollment.enroll(%{
        "join_code" => "OTHER-1",
        "subject" => "aaaaaaaa-3c2a-4f10-9d55-a1b2c3d4e5f6",
        "device_id" => "bbbbbbbb-5e6f-4071-8293-a4b5c6d7e8f9",
        "platform" => "ios"
      })

    # A bundle can carry its study's join code, so this would hand out the means to enrol.
    conn = get(authed(ctx.conn, outsider), "/v1/studies/#{ctx.study.id}/protocol")
    assert json_response(conn, 403)
  end

  test "an unauthenticated request is refused", ctx do
    conn = get(ctx.conn, "/v1/studies/#{ctx.study.id}/protocol")
    assert json_response(conn, 401)
  end

  test "a study cannot be stored with a hash that does not describe its bytes" do
    {:error, changeset} =
      Studies.create_study(%{
        name: "Mismatched",
        protocol_source: ~s({"modules":{}}),
        protocol_hash: "sha256:#{String.duplicate("0", 64)}"
      })

    assert {"does not match protocol_source", _} = changeset.errors[:protocol_hash]
  end

  test "the reference bundle round-trips through registration unchanged", ctx do
    assert Studies.fetch_protocol_source(ctx.study.id) == {:ok, ctx.source}
    assert ctx.study.protocol["modules"] |> Map.keys() == ["proximity"]
  end
end
