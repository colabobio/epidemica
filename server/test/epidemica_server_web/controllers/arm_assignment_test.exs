defmodule EpidemicaServerWeb.ArmAssignmentTest do
  @moduledoc """
  Drawing a participant's arm when they join.

  The draw is the experiment. What matters is that it happens once, at enrolment, that the answer
  reaches the app so its scoring mirror agrees with the ledger, and that nothing afterwards can move
  a participant between conditions.
  """

  use EpidemicaServerWeb.ConnCase, async: true

  alias EpidemicaServer.Studies

  defp bundle(title, rules) do
    Jason.encode!(%{
      "bundle_version" => "1.0",
      "study_id" => Ecto.UUID.generate(),
      "title" => title,
      "modules" => %{"proximity" => %{}},
      "rules" => rules
    })
  end

  defp randomised_rules do
    %{
      "engine" => "epigame",
      "pars" => %{"protection_cost" => 1},
      "arms" => [
        %{"name" => "low", "weight" => 1, "pars" => %{}},
        %{"name" => "high", "weight" => 1, "pars" => %{"protection_cost" => 2}}
      ]
    }
  end

  defp randomised_study(code) do
    {:ok, study} =
      Studies.create_study_from_bundle("Randomised", bundle("Randomised", randomised_rules()))

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

  test "everyone who joins lands in a declared arm", %{conn: conn} do
    randomised_study("ARMS-1")

    for n <- 1..20 do
      assert join(conn, "ARMS-1", subject(n))["arm"] in ["low", "high"]
    end
  end

  test "the draw splits roughly by weight", %{conn: conn} do
    randomised_study("ARMS-2")

    arms = for n <- 1..60, do: join(conn, "ARMS-2", subject(n))["arm"]

    # A 1:1 study that puts nobody in one arm is broken, not unlucky. Loose bounds because this is
    # a draw and a test tight enough to pin it would fail on a fair one.
    assert Enum.count(arms, &(&1 == "low")) > 10
    assert Enum.count(arms, &(&1 == "high")) > 10
  end

  test "rejoining keeps the arm rather than redrawing", %{conn: conn} do
    randomised_study("ARMS-3")

    first = join(conn, "ARMS-3", "someone-00000000")
    again = join(conn, "ARMS-3", "someone-00000000")

    # A reinstall that redrew would quietly move a participant between conditions, mid-study, with
    # their earlier days already scored under the other arm.
    assert again["arm"] == first["arm"]
  end

  test "a study that does not randomise answers with no arm", %{conn: conn} do
    source = bundle("One group", %{"engine" => "epigame", "pars" => %{}})
    {:ok, study} = Studies.create_study_from_bundle("One group", source)
    {:ok, _} = Studies.add_join_code(study, "PLAIN-1")

    assert join(conn, "PLAIN-1", "someone-00000000")["arm"] == nil
  end

  test "a code may still carry an arm when the study does not randomise", %{conn: conn} do
    source = bundle("Stratified", %{"engine" => "epigame", "pars" => %{}})
    {:ok, study} = Studies.create_study_from_bundle("Stratified", source)
    {:ok, _} = Studies.add_join_code(study, "POSTER-1", "poster")

    # The other experiment: stratification by which code somebody was handed.
    assert join(conn, "POSTER-1", "someone-00000000")["arm"] == "poster"
  end

  test "a randomised study refuses a code that also stamps an arm" do
    source = bundle("Both", randomised_rules())
    {:ok, study} = Studies.create_study_from_bundle("Both", source)

    # Two mechanisms that both decide the arm, and only one can win. Refused rather than resolved
    # by precedence: silently dropping one loses a design the researcher wrote down.
    assert {:error, :study_randomises_arms} = Studies.add_join_code(study, "BOTH-1", "poster")
    assert {:error, :study_randomises_arms} = Studies.move_join_code(study, "BOTH-1", "poster")
    assert Studies.join_code_owner("BOTH-1") == nil, "a refused code must leave nothing behind"
  end

  test "two arms sharing a name are refused at registration" do
    source =
      bundle("Ambiguous", %{
        "engine" => "epigame",
        "pars" => %{},
        "arms" => [
          %{"name" => "low", "weight" => 1, "pars" => %{}},
          %{"name" => "low", "weight" => 1, "pars" => %{"protection_cost" => 2}}
        ]
      })

    # The name is what analysis splits by, so two arms sharing one merges the conditions into a
    # single group and leaves no trace that it happened.
    assert {:error, {:arms_share_a_name, ["low"]}} =
             Studies.create_study_from_bundle("Ambiguous", source)
  end

  test "an arm that changes what counts as a contact is refused at registration" do
    source =
      bundle("Smuggled", %{
        "engine" => "epigame",
        "pars" => %{},
        "arms" => [
          %{"name" => "lenient", "weight" => 1, "pars" => %{"contact_min_seconds" => 60}}
        ]
      })

    # An encounter joins two people. If their arms disagreed about whether it lasted long enough,
    # there would be no answer fair to both, so only prices may vary.
    assert {:error, {:invalid_bundle, _}} = Studies.create_study_from_bundle("Smuggled", source)
  end
end
