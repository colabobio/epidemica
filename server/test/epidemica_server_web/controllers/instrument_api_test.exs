defmodule EpidemicaServerWeb.InstrumentApiTest do
  @moduledoc """
  Serving instrument definitions.

  The device refuses a definition whose digest differs from what the bundle pinned, so the only
  thing that matters here is that the bytes come back exactly as registered, and that they come
  back only to a device enrolled in the study that registered them.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, Instruments, Studies}

  @definition ~s({"instrument_version":"1.0","instrument_id":"checkin","version":"1.0.0","title":"A quick check-in","items":[{"item_id":"felt_unwell","type":"single_choice","prompt":"Have you felt unwell?","options":[{"value":1,"label":"Yes"},{"value":0,"label":"No"}]}]})

  defp study_named(name, code) do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => name,
        "modules" => %{"survey" => %{}}
      })

    {:ok, study} = Studies.create_study_from_bundle(name, source)
    {:ok, _} = Studies.add_join_code(study, code)
    study
  end

  setup %{conn: conn} do
    study = study_named("With instruments", "JOIN-A")
    {:ok, _} = Instruments.register(study.id, @definition)

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "JOIN-A",
        "subject" => "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6",
        "device_id" => "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
        "platform" => "android"
      })

    {:ok, conn: conn, study: study, enrolled: enrolled}
  end

  defp authed(conn, %{access_token: token}),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "the bytes come back exactly as registered", ctx do
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/instruments/checkin/1.0.0")

    # Byte-for-byte, never a re-encoding: the device hashes what it receives and compares it with
    # what the bundle pinned, and a document that round-trips through a decoder can come back with
    # a different key order and a different digest.
    assert response(conn, 200) == @definition
    assert response_content_type(conn, :json) =~ "application/json"
  end

  test "an unknown version is a 404 rather than a stale answer", ctx do
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/instruments/checkin/9.9.9")

    assert json_response(conn, 404)["title"] == "no_such_instrument"
  end

  test "a device cannot read another study's questions", ctx do
    other = study_named("Somewhere else", "JOIN-B")
    theirs = String.replace(@definition, ~s("version":"1.0.0"), ~s("version":"7.0.0"))
    {:ok, _} = Instruments.register(other.id, theirs)

    # Only the other study registered version 7. The study comes from the token and there is no
    # path parameter naming one, so this is a 404 from a query that never left this participant's
    # own study rather than a permission check that could be got round.
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/instruments/checkin/7.0.0")

    assert json_response(conn, 404)["title"] == "no_such_instrument"
  end

  test "an anonymous request is refused", ctx do
    conn = get(ctx.conn, "/v1/instruments/checkin/1.0.0")

    assert conn.status == 401
  end

  describe "registering" do
    test "identical bytes register once, so seeding twice is safe", ctx do
      assert {:ok, first} = Instruments.register(ctx.study.id, @definition)
      assert {:ok, again} = Instruments.register(ctx.study.id, @definition)

      assert first.id == again.id
      assert length(Instruments.list(ctx.study.id)) == 1
    end

    test "different bytes under the same version are refused", ctx do
      edited = String.replace(@definition, "Have you felt unwell?", "Have you felt ill?")

      # Responses already collected name this version. Quietly changing what it means would merge
      # two different measurements into one, and nothing downstream could tell.
      assert {:error, {:version_already_registered, "checkin", "1.0.0"}} =
               Instruments.register(ctx.study.id, edited)
    end

    test "a new version sits alongside the old one", ctx do
      revised = String.replace(@definition, ~s("version":"1.0.0"), ~s("version":"1.1.0"))

      assert {:ok, _} = Instruments.register(ctx.study.id, revised)
      assert length(Instruments.list(ctx.study.id)) == 2
    end

    test "a document that is not an instrument is refused", ctx do
      assert {:error, :not_an_instrument} = Instruments.register(ctx.study.id, ~s({"hello":true}))
    end
  end
end
