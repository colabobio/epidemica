defmodule EpidemicaServerWeb.GameActionTest do
  @moduledoc """
  Taking and releasing protection.

  Protection costs points and changes who the simulation lets a participant infect, so the decision
  has to be answerable from the record. These tests hold the boundary that makes it so: the server
  decides when it took effect, and one participant can never act for another.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.{Enrollment, Epigame, ParticipantState, Studies}

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

  # A study that has already finished, so every action arrives too late.
  defp finished_study(conn) do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Over",
        "modules" => %{"proximity" => %{}},
        "schedule" => %{"starts_at" => "2020-01-01T00:00:00Z", "days" => 7},
        "rules" => %{"engine" => "epigame"}
      })

    {:ok, study} = Studies.create_study_from_bundle("Over", source)
    {:ok, _} = Studies.add_join_code(study, "OVER-1")

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "OVER-1",
        "subject" => "9c2e0f55-4d3b-4021-8e66-b2c3d4e5f607",
        "device_id" => "2b3c4d5e-6f70-4182-93a4-b5c6d7e8f901",
        "platform" => "android"
      })

    %{conn: conn, study: study, enrolled: enrolled}
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

  describe "the decision is visible at once" do
    test "enrolling publishes a starting state, so there is something to update", ctx do
      {:ok, document} = ParticipantState.fetch(ctx.study.id, ctx.enrolled.subject)

      assert document.state["day"] == 0
      assert document.state["epi_state"] == "susceptible"
      assert document.state["points"] == 0
    end

    test "taking protection answers with when it lapses", ctx do
      body = json_response(act(ctx, %{"action" => "protect"}), 200)

      assert {:ok, until, _} = DateTime.from_iso8601(body["protected_until"])
      assert DateTime.compare(until, DateTime.utc_now()) == :gt
    end

    test "taking protection updates the published state before any tick", ctx do
      {:ok, before} = ParticipantState.fetch(ctx.study.id, ctx.enrolled.subject)
      assert before.state["protected_until"] == nil

      body = json_response(act(ctx, %{"action" => "protect"}), 200)

      # The app renders the state document, so protection that only appeared at settlement would
      # leave a player with no confirmation that their tap did anything for a whole day.
      {:ok, document} = ParticipantState.fetch(ctx.study.id, ctx.enrolled.subject)
      assert document.state["protected_until"] == body["protected_until"]
      assert document.revision > before.revision
    end

    test "releasing clears it just as promptly", ctx do
      act(ctx, %{"action" => "protect"})
      assert json_response(act(ctx, %{"action" => "release"}), 200)["protected_until"] == nil

      {:ok, document} = ParticipantState.fetch(ctx.study.id, ctx.enrolled.subject)
      assert document.state["protected_until"] == nil
    end
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

  test "a decision cannot be taken after the study has ended", ctx do
    over = finished_study(ctx.conn)

    body = json_response(act(over, %{"action" => "protect"}), 409)

    # Protection taken after the last day would be charged for on a day that will never be
    # settled, so it is refused rather than recorded and quietly ignored.
    assert body["title"] == "study_not_running"
  end

  test "a decision cannot be taken before the study begins", ctx do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Later",
        "modules" => %{"proximity" => %{}},
        "schedule" => %{"starts_at" => "2099-01-01T00:00:00Z", "days" => 7},
        "rules" => %{"engine" => "epigame"}
      })

    {:ok, study} = Studies.create_study_from_bundle("Later", source)
    {:ok, _} = Studies.add_join_code(study, "LATER-1")

    {:ok, enrolled} =
      Enrollment.enroll(%{
        "join_code" => "LATER-1",
        "subject" => "3f4e5d66-7a8b-4c90-9d11-e2f3a4b5c6d7",
        "device_id" => "3c4d5e6f-7081-4293-a4b5-c6d7e8f90123",
        "platform" => "android"
      })

    # Enrolling early is fine — codes go out before play starts — but acting early is not.
    body =
      json_response(act(%{conn: ctx.conn, enrolled: enrolled}, %{"action" => "protect"}), 409)

    assert body["title"] == "study_not_running"
    assert study.id
  end
end
