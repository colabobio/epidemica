defmodule EpidemicaServerWeb.ArmAssignmentTest do
  @moduledoc """
  Assigning a participant to an arm when they join.

  The draw is the whole experiment, so the thing that matters here is that it happens at enrolment,
  once, and that the answer is in the response the app will score against. A participant who is
  never assigned plays the default; one reassigned later is a different measurement.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.Studies

  defp randomised_study(code) do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Randomised",
        "modules" => %{"proximity" => %{}},
        "rules" => %{
          "engine" => "epigame",
          "pars" => %{"protection_cost" => 1},
          "arms" => [
            %{"name" => "low", "weight" => 1, "pars" => %{}},
            %{"name" => "high", "weight" => 1, "pars" => %{"protection_cost" => 2}}
          ]
        }
      })

    {:ok, study} = Studies.create_study_from_bundle("Randomised", source)
    {:ok, _} = Studies.add_join_code(study, code)
    study
  end

  defp join(conn, code, subject) do
    conn
    |> post("/v1/enrollments", %{
      "join_code" => code,
      "subject" => subject,
      "device_id" => Ecto.UUID.generate(),
      "platform" => "android"
    })
    |> json_response(201)
  end

  defp subject(n), do: "subject-#{String.pad_leading("#{n}", 8, "0")}"

  test "everyone who joins lands in a named arm", %{conn: conn} do
    randomised_study("ARMS-1")

    for n <- 1..20 do
      assert join(conn, "ARMS-1", subject(n))["arm"] in ["low", "high"]
    end
  end

  test "the draw splits roughly by weight", %{conn: conn} do
    randomised_study("ARMS-2")

    arms = for n <- 1..60, do: join(conn, "ARMS-2", subject(n))["arm"]

    assert Enum.all?(arms, &(&1 in ["low", "high"]))
    # A 1:1 study that never lands anyone in one arm is broken, not unlucky. Loose bounds on
    # purpose: the draw is a draw, and tight ones flake.
    assert Enum.count(arms, &(&1 == "low")) > 10
    assert Enum.count(arms, &(&1 == "high")) > 10
  end

  test "rejoining keeps the arm rather than redrawing", %{conn: conn} do
    randomised_study("ARMS-3")

    device = Ecto.UUID.generate()
    first = join(conn, "ARMS-3", "someone-00000000")

    again =
      conn
      |> post("/v1/enrollments", %{
        "join_code" => "ARMS-3",
        "subject" => "someone-00000000",
        "device_id" => device,
        "platform" => "android"
      })
      |> json_response(201)

    # The assignment is the experiment. A reinstall that redrew it would quietly move a participant
    # between conditions.
    assert again["arm"] == first["arm"]
  end

  test "a study without arms answers with none", %{conn: conn} do
    source =
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "One group",
        "modules" => %{"proximity" => %{}},
        "rules" => %{"engine" => "epigame", "pars" => %{}}
      })

    {:ok, study} = Studies.create_study_from_bundle("One group", source)
    {:ok, _} = Studies.add_join_code(study, "PLAIN-1")

    assert join(conn, "PLAIN-1", "someone-00000000")["arm"] == nil
  end
end
