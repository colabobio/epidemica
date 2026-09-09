defmodule EpidemicaServer.SeedStudyTest do
  @moduledoc """
  Registering a study from an authored bundle, and the join code that makes it reachable.

  A join code is unique across every study, so seeding one that is already held has to be refused.
  The failure it replaces was silent in the worst direction: the study registered, printed an id and
  a `flutter run` line, and had no way in, while every device using the code enrolled in the study
  that held it. Nothing surfaced until a participant could not join, typically in a room with people
  waiting.
  """

  use EpidemicaServer.DataCase, async: false

  import Ecto.Query

  alias EpidemicaServer.{Repo, Studies}
  alias EpidemicaServer.Studies.Study

  setup do
    dir = Path.join(System.tmp_dir!(), "seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # Two bundles that differ only in when the study starts: the shape of re-seeding during
  # development, and the shape that produced the bug.
  defp bundle_at(dir, starts_at) do
    path = Path.join(dir, "bundle-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "bundle_version" => "1.0",
        "study_id" => Ecto.UUID.generate(),
        "title" => "Seeded",
        "join_code" => "SEED-CODE",
        "modules" => %{"proximity" => %{}},
        "schedule" => %{"starts_at" => starts_at, "days" => 7}
      })
    )

    path
  end

  defp seed(args) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Epidemica.SeedStudy.run(args)
    after
      Mix.shell(shell)
    end
  end

  defp study_count, do: Repo.one(from s in Study, select: count())

  test "a bundle registers and its code is attached", %{dir: dir} do
    seed(["--bundle", bundle_at(dir, "2026-09-07T06:00:00Z")])

    assert {:ok, found} = Studies.fetch_join_code("SEED-CODE")
    assert Repo.get(Study, found.study_id)
  end

  test "seeding the same bundle twice changes nothing", %{dir: dir} do
    path = bundle_at(dir, "2026-09-07T06:00:00Z")
    seed(["--bundle", path])
    before = study_count()

    seed(["--bundle", path])

    assert study_count() == before
  end

  test "a code held by another study is refused, and no study is left behind", %{dir: dir} do
    seed(["--bundle", bundle_at(dir, "2026-09-07T06:00:00Z")])
    {:ok, original} = Studies.fetch_join_code("SEED-CODE")
    before = study_count()

    # The teeth of this test are the count, not the raise. A version that refuses *after* creating
    # the study would pass on the exception alone while still leaving the litter that made the
    # original bug so confusing to diagnose.
    assert_raise Mix.Error, ~r/already belongs to study/, fn ->
      seed(["--bundle", bundle_at(dir, "2026-09-08T06:00:00Z")])
    end

    assert study_count() == before, "a refused seed must not leave a study behind"
    assert {:ok, still} = Studies.fetch_join_code("SEED-CODE")
    assert still.study_id == original.study_id, "the code must still reach the study that held it"
  end

  test "a changed bundle under a fresh code registers, and both are reachable", %{dir: dir} do
    seed(["--bundle", bundle_at(dir, "2026-09-07T06:00:00Z")])
    seed(["--bundle", bundle_at(dir, "2026-09-08T06:00:00Z"), "--code", "SEED-OTHER"])

    assert {:ok, first} = Studies.fetch_join_code("SEED-CODE")
    assert {:ok, second} = Studies.fetch_join_code("SEED-OTHER")
    assert first.study_id != second.study_id
  end

  test "--steal-code moves it, which is what development actually wants", %{dir: dir} do
    seed(["--bundle", bundle_at(dir, "2026-09-07T06:00:00Z")])
    {:ok, original} = Studies.fetch_join_code("SEED-CODE")

    seed(["--bundle", bundle_at(dir, "2026-09-08T06:00:00Z"), "--steal-code"])

    assert {:ok, moved} = Studies.fetch_join_code("SEED-CODE")
    assert moved.study_id != original.study_id
    assert Repo.get(Study, original.study_id), "the old study stays, it is merely unreachable"
  end

  test "the refusal says what to do about it", %{dir: dir} do
    seed(["--bundle", bundle_at(dir, "2026-09-07T06:00:00Z")])

    message =
      assert_raise Mix.Error, fn ->
        seed(["--bundle", bundle_at(dir, "2026-09-08T06:00:00Z")])
      end

    # An operator reading this is mid-session and needs the way out, not a diagnosis.
    assert message.message =~ "--steal-code"
    assert message.message =~ "--code"
    assert message.message =~ "Nothing has been created"
  end
end
