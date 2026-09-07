defmodule EpidemicaServerWeb.ParticipantStateTest do
  @moduledoc """
  The downward channel.

  Held to `contracts/state/participant_state/1.0.0.json` directly, because this is the first thing
  the server tells a device about a person and the shape has to be exactly what clients validate.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, ParticipantState, Studies}

  @state_uri "https://schemas.epidemica.info/state/epigame/1.0.0.json"
  @bundle_path Path.expand("../../../../studies/contactlog/bundle.json", __DIR__)

  setup %{conn: conn} do
    {:ok, study} = Studies.create_study_from_bundle("Epigame pilot", File.read!(@bundle_path))
    {:ok, _} = Studies.add_join_code(study, "PLAY-1")

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "PLAY-1",
        "subject" => "7b1d9e44-3c2a-4f10-9d55-a1b2c3d4e5f6",
        "device_id" => "1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9",
        "platform" => "android"
      })

    {:ok, conn: conn, study: study, enrolled: enrolled}
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

  # The state is validated against its contract on the way out, so a test varying one field still
  # has to supply a document the study would actually publish.
  defp state(overrides) do
    Map.merge(
      %{"day" => 4, "days_total" => 7, "epi_state" => "susceptible", "points" => 0},
      overrides
    )
  end

  defp put_state(ctx, state, as_of \\ ~U[2026-09-04 03:00:00.000000Z]) do
    ParticipantState.put(ctx.study.id, ctx.enrolled.subject, @state_uri, state, as_of)
  end

  test "before anything is computed there is no state, rather than an invented one", ctx do
    conn = get(authed(ctx.conn, ctx.enrolled), "/v1/participants/me/state")

    body = json_response(conn, 404)
    assert body["title"] == "no_state_yet"
  end

  test "serves a document in the shape clients validate", ctx do
    {:ok, _} =
      put_state(ctx, %{
        "day" => 4,
        "days_total" => 7,
        "epi_state" => "susceptible",
        "points" => 11
      })

    body = json_response(get(authed(ctx.conn, ctx.enrolled), "/v1/participants/me/state"), 200)

    # Held to the contract itself, not to a hand-written expectation of it.
    assert :ok = EpidemicaServer.Contracts.validate_participant_state(body)
    assert :ok = EpidemicaServer.Contracts.validate_state(@state_uri, body["state"])

    assert body["state_version"] == "1.0"
    assert body["study_id"] == ctx.study.id
    assert body["subject"] == ctx.enrolled.subject
    assert body["state_uri"] == @state_uri
    assert body["state"]["points"] == 11
  end

  test "a state document that violates the study's own contract is caught", _ctx do
    # The server validates what it sends, because a malformed document would be refused by every
    # client at once and this is where that is cheap to notice.
    assert {:error, _} =
             EpidemicaServer.Contracts.validate_state(@state_uri, %{
               "day" => 4,
               "days_total" => 7,
               "epi_state" => "exposed",
               "points" => 11
             })
  end

  test "a study whose state contract this build has never seen still passes through", _ctx do
    # Refusing unknown state shapes would make the channel useless to the studies it exists for.
    assert :ok =
             EpidemicaServer.Contracts.validate_state(
               "https://schemas.epidemica.info/state/adherence/1.0.0.json",
               %{"streak_days" => 12}
             )
  end

  test "the revision moves forward on every write", ctx do
    {:ok, first} = put_state(ctx, state(%{"points" => 1}))
    {:ok, second} = put_state(ctx, state(%{"points" => 2}))
    {:ok, third} = put_state(ctx, state(%{"points" => 3}))

    assert first.revision == 1
    assert second.revision == 2
    assert third.revision == 3

    body = json_response(get(authed(ctx.conn, ctx.enrolled), "/v1/participants/me/state"), 200)
    assert body["revision"] == 3
    assert body["state"] == state(%{"points" => 3})
  end

  test "concurrent writers cannot land on the same revision", ctx do
    # Read-then-write would let two callers both see revision 4 and both write 5, and a client
    # would then treat a stale document as current.
    parent = self()

    tasks =
      for n <- 1..10 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(EpidemicaServer.Repo, parent, self())
          {:ok, doc} = put_state(ctx, state(%{"points" => n}))
          doc.revision
        end)
      end

    revisions = tasks |> Task.await_many() |> Enum.sort()

    assert revisions == Enum.to_list(1..10)
  end

  test "state is scoped to the token, not to a path parameter", ctx do
    {:ok, other} = Studies.create_study_from_bundle("Other", other_bundle("Other"))
    {:ok, _} = Studies.add_join_code(other, "OTHER-1")

    {:ok, outsider} =
      Enrollment.enroll(%{
        "join_code" => "OTHER-1",
        "subject" => "aaaaaaaa-3c2a-4f10-9d55-a1b2c3d4e5f6",
        "device_id" => "bbbbbbbb-5e6f-4071-8293-a4b5c6d7e8f9",
        "platform" => "ios"
      })

    {:ok, _} = put_state(ctx, state(%{"points" => 11}))

    # There is no way to name another participant, so the outsider simply has no state of their own.
    conn = get(authed(ctx.conn, outsider), "/v1/participants/me/state")
    assert json_response(conn, 404)
  end

  test "an unauthenticated request is refused", ctx do
    assert json_response(get(ctx.conn, "/v1/participants/me/state"), 401)
  end

  test "state is validated against its contract before it is stored", ctx do
    # A client cannot catch this for us: `state` is opaque to core, and a study renderer reading a
    # missing field leniently shows a default, which on screen is indistinguishable from a computed
    # answer. Caught once here rather than by every client at once.
    assert {:error, {:invalid_state, _}} = put_state(ctx, %{"day" => 4})

    assert {:error, :not_found} = ParticipantState.fetch(ctx.study.id, ctx.enrolled.subject)
  end

  test "a state shape this build has never seen passes through", ctx do
    # Refusing an unknown `state_uri` would make the channel useless to exactly the studies it
    # exists for, and mirrors how an unknown `schema_uri` is quarantined rather than rejected.
    assert {:ok, doc} =
             ParticipantState.put(
               ctx.study.id,
               ctx.enrolled.subject,
               "https://schemas.example.org/state/something_else/1.0.0.json",
               %{"anything" => true}
             )

    assert doc.state == %{"anything" => true}
  end

  test "writing state for someone who is not enrolled fails rather than creating them", ctx do
    assert {:error, :no_such_participant} =
             ParticipantState.put(ctx.study.id, "not-a-participant", @state_uri, %{})
  end

  test "as_of records when the computation ran, not when it was served", ctx do
    computed_at = ~U[2026-09-01 03:00:00.000000Z]
    {:ok, _} = put_state(ctx, state(%{"points" => 2}), computed_at)

    body = json_response(get(authed(ctx.conn, ctx.enrolled), "/v1/participants/me/state"), 200)

    # A daily study is a day stale by design; the interface has to be able to say so rather than
    # implying the number is live.
    assert body["as_of"] == "2026-09-01T03:00:00.000000Z"
  end
end
