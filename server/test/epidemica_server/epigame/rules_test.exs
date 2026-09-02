defmodule EpidemicaServer.Epigame.RulesTest do
  @moduledoc """
  The scoring rules, against the vectors the app must also satisfy.

  These are the same file the Dart implementation will run. A test that only checked Elixir against
  Elixir would let the two rule sets drift apart while both stayed green, which is exactly the
  failure ADR-0012 was written about.
  """

  use ExUnit.Case, async: true

  alias EpidemicaServer.Epigame.Rules

  @vectors_path Path.expand(
                  "../../../../contracts/game/epigame_rules/1.0.0.vectors.json",
                  __DIR__
                )
  @external_resource @vectors_path

  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  defp facts(map) do
    %{
      day: map["day"],
      opening: map["opening"],
      epi_state: map["epi_state"],
      observed: map["observed"],
      protection: map["protection"],
      contacts: map["contacts"],
      carried_over: map["carried_over"]
    }
  end

  defp normalise(%{lines: lines} = settlement) do
    settlement
    |> Map.put(:lines, Enum.map(lines, &Map.new(&1, fn {k, v} -> {to_string(k), v} end)))
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  describe "settlement vectors" do
    for {vector, index} <- Enum.with_index(@vectors["settlements"]) do
      @vector vector
      test "#{index}: #{vector["case"]}" do
        pars = Map.merge(@vectors["pars"], @vector["pars"] || %{})
        settlement = Rules.settle(pars, facts(@vector["facts"]))

        assert normalise(settlement) == @vector["expect"]
      end
    end

    test "the lines always account for the whole movement" do
      # The point of showing a participant the arithmetic is that it can be checked. JSON Schema
      # cannot sum an array, so this invariant has to be enforced here.
      for vector <- @vectors["settlements"] do
        pars = Map.merge(@vectors["pars"], vector["pars"] || %{})
        s = Rules.settle(pars, facts(vector["facts"]))

        assert s.closing - s.opening == Enum.sum(Enum.map(s.lines, & &1.points)),
               "settlement does not add up: #{vector["case"]}"
      end
    end

    test "a settled day always explains itself" do
      for vector <- @vectors["settlements"] do
        pars = Map.merge(@vectors["pars"], vector["pars"] || %{})
        s = Rules.settle(pars, facts(vector["facts"]))

        # A balance that did not move still says why. An unexplained gap is the thing a participant
        # cannot argue with.
        assert s.lines != []
      end
    end
  end

  describe "award vectors" do
    for {vector, index} <- Enum.with_index(@vectors["awards"]) do
      @vector vector
      test "#{index}: #{vector["case"]}" do
        network =
          Enum.map(@vector["network"], fn edge ->
            [a, b] = edge["pair"]
            %{pair: {a, b}, seconds: edge["seconds"]}
          end)

        protected = MapSet.new(@vector["protected"])
        awarded = MapSet.new(@vector["already_awarded"], fn [a, b] -> {a, b} end)

        awards = Rules.award_contacts(@vectors["pars"], network, protected, awarded)

        assert Enum.map(awards, fn {a, b} -> [a, b] end) == @vector["expect"]
      end
    end
  end

  describe "constants" do
    test "every constant comes from the bundle" do
      pars = Rules.pars(%{"pars" => %{"healthy_points" => 7}})

      assert pars["healthy_points"] == 7
      # A study that overrides one constant must still get sane values for the rest, or changing
      # one number would silently zero the others.
      assert pars["contact_points"] == 5
    end

    test "a study with no rule constants still has a complete set" do
      assert Rules.pars(%{})["healthy_points"] == 2
      assert Rules.pars(nil)["protection_cost"] == 1
    end
  end
end
