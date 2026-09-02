defmodule EpidemicaServerWeb.GameActionTest do
  @moduledoc """
  Taking and releasing protection.

  Protection costs points and changes who the simulation lets a participant infect, so the decision
  has to be answerable from the record. These tests hold the boundary that makes it so: the server
  decides when it took effect, and one participant can never act for another.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, Epigame, Studies}

  setup %{conn: conn} do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Epigame pilot",
        "modules" => %{"proximity" => %{}},
        "rules" => %{"engine" => "epigame", "pars" => %{"protection_window_seconds" => 3600}}
      })

    {:ok, study} = Studies.create_study_from_bundle("Epigame pilot", source)
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

  defp authed(conn, %{access_token: token}),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp act(ctx, body),
    do: post(authed(ctx.conn, ctx.enrolled), "/v1/participants/me/actions", body)

  test "a participant can take protection", ctx do
    body = json_response(act(ctx, %{"action" => "protect"}), 200)
    assert body["accepted"] == true

    now = DateTime.utc_now()
    protected = Epigame.chosen_protection(ctx.study.id, now, DateTime.add(now, 60, :second))
    assert MapSet.member?(protected, ctx.enrolled.subject)
  end

  test "protection cannot be backdated by the client", ctx do
    long_ago = ~U[2020-01-01 00:00:00.000000Z]
    act(ctx, %{"action" => "protect", "at" => DateTime.to_iso8601(long_ago)})

    # A participant who could name their own effective time could protect themselves after learning
    # they were exposed, which would make the cost of protection avoidable and the measurement void.
    protected =
      Epigame.chosen_protection(ctx.study.id, long_ago, DateTime.add(long_ago, 3600, :second))

    assert MapSet.equal?(protected, MapSet.new())
  end

  test "the bundle's window governs how long protection lasts", ctx do
    act(ctx, %{"action" => "protect"})

    now = DateTime.utc_now()
    within = DateTime.add(now, 1800, :second)
    beyond = DateTime.add(now, 7200, :second)

    assert MapSet.member?(
             Epigame.chosen_protection(ctx.study.id, within, DateTime.add(within, 1, :second)),
             ctx.enrolled.subject
           )

    refute MapSet.member?(
             Epigame.chosen_protection(ctx.study.id, beyond, DateTime.add(beyond, 1, :second)),
             ctx.enrolled.subject
           )
  end

  test "a participant can release protection early", ctx do
    act(ctx, %{"action" => "protect"})
    assert json_response(act(ctx, %{"action" => "release"}), 200)["accepted"] == true
  end

  test "releasing when unprotected is a conflict, not a silent success", ctx do
    body = json_response(act(ctx, %{"action" => "release"}), 409)
    assert body["title"] == "not_protected"
  end

  test "an unknown action is refused", ctx do
    body = json_response(act(ctx, %{"action" => "teleport"}), 400)
    assert body["title"] == "unknown_action"
  end

  test "an unauthenticated device cannot act", ctx do
    conn = post(ctx.conn, "/v1/participants/me/actions", %{"action" => "protect"})
    assert conn.status in [401, 403]
  end
end
