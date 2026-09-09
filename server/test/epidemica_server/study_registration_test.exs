defmodule EpidemicaServer.StudyRegistrationTest do
  @moduledoc """
  What a bundle has to be before a study is made from it.

  Registration is the last moment anyone is watching. The bundle schema is closed at the top level,
  so a mistyped key is not an error at run time but a setting that keeps its default for the length
  of the study; and a study whose devices cannot report coverage fast enough does not fail either,
  it runs to completion having simulated nothing. Both are caught here or not at all.
  """

  use EpidemicaServer.DataCase, async: true

  alias EpidemicaServer.Studies

  @studies_dir Path.expand("../../../studies", __DIR__)

  defp register(protocol), do: Studies.create_study_from_bundle("test", Jason.encode!(protocol))

  defp bundle(overrides \\ %{}) do
    Map.merge(
      %{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Test study",
        "modules" => %{"proximity" => %{}}
      },
      overrides
    )
  end

  defp twin(overrides \\ %{}) do
    Map.merge(
      %{
        "engine" => "starsim",
        "state_uri" => "https://schemas.epidemica.info/state/epigame/1.0.0.json",
        "population" => 4
      },
      overrides
    )
  end

  describe "the reference studies" do
    test "every bundle in studies/ registers" do
      paths = Path.wildcard(Path.join(@studies_dir, "*/bundle.json"))
      assert paths != [], "no reference bundles found to check"

      for path <- paths do
        assert {:ok, _} = Studies.create_study_from_bundle(Path.basename(path), File.read!(path)),
               "#{path} no longer registers"
      end
    end
  end

  describe "the contract" do
    test "a mistyped top-level key is refused rather than ignored" do
      # The whole point of a closed schema: `helth` would otherwise leave coverage reporting on its
      # default for the study's entire run, with nothing to look at afterwards that says why.
      assert {:error, {:invalid_bundle, error}} = register(bundle(%{"helth" => %{}}))
      assert error[:instance_location] == "/helth"
    end

    test "a bundle missing a required field is refused" do
      assert {:error, {:invalid_bundle, error}} =
               register(bundle() |> Map.delete("title"))

      assert error[:required] == "/title"
    end

    test "a bundle that is not JSON is refused before anything else" do
      assert {:error, %Jason.DecodeError{}} = Studies.create_study_from_bundle("test", "{")
    end

    test "nothing is written when a bundle is refused" do
      before = Repo.aggregate(Studies.Study, :count)
      assert {:error, _} = register(bundle(%{"helth" => %{}}))
      assert Repo.aggregate(Studies.Study, :count) == before
    end
  end

  describe "a study that could never observe anybody" do
    test "reporting coverage more slowly than it ticks is refused" do
      assert {:error, {:health_interval_too_long, 3600, 150}} =
               register(bundle(%{"twin" => twin(%{"tick_interval_seconds" => 300})}))
    end

    test "the same study passes once its coverage windows keep up" do
      assert {:ok, _} =
               register(
                 bundle(%{
                   "twin" => twin(%{"tick_interval_seconds" => 300}),
                   "health" => %{"interval_seconds" => 60}
                 })
               )
    end

    test "a tighter threshold demands faster reporting" do
      # Coverage cannot exceed 1 - interval/tick, because the window in progress has not been
      # reported yet. Asking for 0.99 of a day therefore rules out an hourly report.
      twin = twin(%{"coverage_threshold" => 0.99})

      assert {:error, {:health_interval_too_long, 3600, 864}} =
               register(bundle(%{"twin" => twin}))

      assert {:ok, _} =
               register(bundle(%{"twin" => twin, "health" => %{"interval_seconds" => 600}}))
    end

    test "switching health reporting off under a twin is refused" do
      # Every participant would sit below the threshold on every day, be modelled as protected, and
      # the epidemic would not spread -- which on screen is a disease that failed to catch on.
      assert {:error, {:coverage_not_reported, _}} =
               register(bundle(%{"twin" => twin(), "health" => %{"enabled" => false}}))
    end

    test "a study that only collects may switch it off, having no model to starve" do
      assert {:ok, _} = register(bundle(%{"health" => %{"enabled" => false}}))
    end
  end

  describe "the coverage threshold" do
    test "comes from the twin block" do
      {:ok, study} = register(bundle(%{"twin" => twin(%{"coverage_threshold" => 0.25})}))
      assert Studies.coverage_threshold(study) == 0.25
    end

    test "defaults for a study that does not state one" do
      {:ok, study} = register(bundle(%{"twin" => twin()}))
      assert Studies.coverage_threshold(study) == 0.5
    end

    test "defaults for a study with no twin at all" do
      {:ok, study} = register(bundle())
      assert Studies.coverage_threshold(study) == 0.5
    end

    test "complete coverage cannot be demanded, because the open window is never reported" do
      assert {:error, {:invalid_bundle, _}} =
               register(bundle(%{"twin" => twin(%{"coverage_threshold" => 1})}))
    end
  end

  describe "join codes" do
    defp study_named(title) do
      {:ok, study} = register(bundle(%{"title" => title}))
      study
    end

    test "a free code is attached" do
      assert {:ok, code} = Studies.add_join_code(study_named("first"), "OPEN-1")
      assert code.code == "OPEN-1"
    end

    test "a study re-attaching its own code is a no-op, so re-seeding stays safe" do
      study = study_named("first")
      {:ok, first} = Studies.add_join_code(study, "SAME-1")

      assert {:ok, again} = Studies.add_join_code(study, "SAME-1")
      assert again.id == first.id
    end

    test "a code belonging to another study is refused, and says which" do
      owner = study_named("first")
      {:ok, _} = Studies.add_join_code(owner, "TAKEN-1")

      # The case that cost a debugging session: a bundle re-seeded with a new start time is a
      # different study, but the code still points at the old one.
      assert {:error, {:code_taken, study_id}} =
               Studies.add_join_code(study_named("second"), "TAKEN-1")

      assert study_id == owner.id
    end

    test "the check does not depend on how the code was capitalised" do
      {:ok, _} = Studies.add_join_code(study_named("first"), "Taken-2")

      assert {:error, {:code_taken, _}} =
               Studies.add_join_code(study_named("second"), "taken-2")
    end

    test "the code still points at the study that holds it" do
      owner = study_named("first")
      {:ok, _} = Studies.add_join_code(owner, "TAKEN-3")
      {:error, _} = Studies.add_join_code(study_named("second"), "TAKEN-3")

      assert {:ok, found} = Studies.fetch_join_code("TAKEN-3")
      assert found.study_id == owner.id
    end

    test "moving a code is possible, but has to be asked for" do
      owner = study_named("first")
      taker = study_named("second")
      {:ok, _} = Studies.add_join_code(owner, "MOVE-1")

      assert {:ok, _} = Studies.move_join_code(taker, "MOVE-1")
      assert {:ok, found} = Studies.fetch_join_code("MOVE-1")
      assert found.study_id == taker.id
    end

    test "moving a code nobody holds simply attaches it" do
      assert {:ok, _} = Studies.move_join_code(study_named("first"), "MOVE-2")
      assert {:ok, _} = Studies.fetch_join_code("MOVE-2")
    end
  end
end
