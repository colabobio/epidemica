defmodule EpidemicaServer.ContractsTest do
  @moduledoc """
  Cross-language agreement on the contracts.

  These run the *same* fixtures as `analysis/tests/test_contracts.py`. A contract is only useful if
  it means the same thing in every language that implements it; a schema that Python accepts and
  Elixir rejects would produce a client and a server that disagree in the field, which is the most
  expensive place to find out.
  """

  use ExUnit.Case, async: true

  alias EpidemicaServer.Contracts

  @contracts_dir Path.expand("../../../contracts", __DIR__)

  defp fixtures(relative_dir, kind) do
    cases =
      @contracts_dir
      |> Path.join("fixtures/#{relative_dir}/#{kind}.json")
      |> File.read!()
      |> Jason.decode!()

    # A `for` comprehension over an empty list passes every assertion inside it. Without this
    # guard, a moved or renamed fixture file would turn these tests green rather than red.
    refute Enum.empty?(cases), "no #{kind} fixtures found for #{relative_dir}"
    cases
  end

  defp envelope_fixtures(kind), do: fixtures("observations/envelope", kind)

  describe "envelope" do
    test "accepts every valid fixture" do
      for %{"case" => name, "instance" => instance} <- envelope_fixtures("valid") do
        assert Contracts.validate_envelope(instance) == :ok, "should have accepted: #{name}"
      end
    end

    test "rejects every invalid fixture" do
      for %{"case" => name, "instance" => instance} <- envelope_fixtures("invalid") do
        assert {:error, _} = Contracts.validate_envelope(instance),
               "should have rejected: #{name}"
      end
    end

    test "does not validate the payload" do
      [%{"instance" => envelope} | _] = envelope_fixtures("valid")
      nonsense = Map.put(envelope, "payload", %{"total" => "nonsense", "not_a_field" => true})
      assert Contracts.validate_envelope(nonsense) == :ok
    end
  end

  describe "payload contracts" do
    for {module_dir, label} <- [
          {"observations/proximity/contact_episode", "contact_episode"},
          {"observations/location/location_fix", "location_fix"},
          {"observations/instruments/survey_response", "survey_response"}
        ] do
      @module_dir module_dir
      @label label

      test "#{@label}: accepts every valid fixture" do
        schema_uri = schema_uri_for(@module_dir)

        for %{"case" => name, "instance" => instance} <- fixtures(@module_dir, "valid") do
          assert Contracts.validate_payload(schema_uri, instance) == :ok,
                 "#{@label} should have accepted: #{name}"
        end
      end

      test "#{@label}: rejects every invalid fixture" do
        schema_uri = schema_uri_for(@module_dir)

        for %{"case" => name, "instance" => instance} <- fixtures(@module_dir, "invalid") do
          assert {:error, _} = Contracts.validate_payload(schema_uri, instance),
                 "#{@label} should have rejected: #{name}"
        end
      end
    end
  end

  describe "unknown schemas" do
    test "are reported rather than raising" do
      assert Contracts.validate_payload("https://example.org/not/ours/1.0.0.json", %{}) ==
               {:error, :unknown_payload_schema}
    end

    test "every known schema URI resolves to a contract that exists on disk" do
      for uri <- Contracts.known_payload_schemas() do
        path = Path.join(@contracts_dir, URI.parse(uri).path |> String.trim_leading("/"))
        assert File.exists?(path), "no contract file for #{uri}"
      end
    end
  end

  defp schema_uri_for(module_dir),
    do: "https://schemas.epidemica.info/#{module_dir}/1.0.0.json"
end
