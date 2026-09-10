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

  describe "arms" do
    defp armed do
      %{
        "pars" => %{"protection_cost" => 1, "contact_points" => 5},
        "arms" => [
          %{"name" => "low", "weight" => 1, "pars" => %{}},
          %{"name" => "high", "weight" => 3, "pars" => %{"protection_cost" => 2}}
        ]
      }
    end

    test "an arm overlays the shared pars" do
      assert Rules.pars_for(armed(), "high")["protection_cost"] == 2

      # Anything the arm does not name stays shared, or naming one constant would zero the rest.
      assert Rules.pars_for(armed(), "high")["contact_points"] == 5
      assert Rules.pars_for(armed(), "low")["protection_cost"] == 1
    end

    test "no arm, and an unknown one, is the shared pars" do
      # A participant who joined before the study randomised still has to be priced.
      assert Rules.pars_for(armed(), nil) == Rules.pars(armed())
      assert Rules.pars_for(armed(), "nobody") == Rules.pars(armed())
    end

    test "a study that declares no arms is one group and is unaffected" do
      assert Rules.arms(%{"pars" => %{}}) == nil
      assert Rules.assign_arm(%{"pars" => %{}}, "s", "subj") == nil

      # Every bundle written before arms existed keeps meaning what it meant.
      assert Rules.pars_for(%{"pars" => %{"protection_cost" => 9}}, "anything") ==
               Rules.pars(%{"pars" => %{"protection_cost" => 9}})
    end

    test "the draw follows the weights" do
      rules = %{
        "arms" => [
          %{"name" => "low", "weight" => 1, "pars" => %{}},
          %{"name" => "high", "weight" => 3, "pars" => %{}}
        ]
      }

      share =
        1..4000
        |> Enum.count(&(Rules.assign_arm(rules, "study", "subject-#{&1}") == "high"))
        |> Kernel./(4000)

      # 3:1, so the truth is 0.75. Bounds rather than an exact figure: this is a draw, and a test
      # tight enough to pin it would fail on a fair one.
      assert share > 0.70
      assert share < 0.80
    end

    test "the same participant is always drawn the same way" do
      # An audit has to be able to re-derive the split from the record, and nothing may move a
      # participant between conditions after the fact.
      assert Rules.assign_arm(armed(), "s1", "subj") == Rules.assign_arm(armed(), "s1", "subj")
    end

    test "every draw lands in an arm that exists" do
      for n <- 1..500 do
        assert Rules.assign_arm(armed(), "s", "s#{n}") in ["low", "high"]
      end
    end

    test "an arm leaves the constants that decide what a contact is alone" do
      # The restriction lives in the bundle schema, in one place, so an arm carrying
      # `contact_min_seconds` never registers. This overlay is a plain merge and does not re-check
      # it -- two lists of permitted keys would eventually disagree, and the schema is the one an
      # author actually meets. What is asserted here is the consequence: an arm that names only
      # prices leaves every pair-level duration at the study's value.
      assert Rules.pars_for(armed(), "high")["contact_min_seconds"] == 600
      assert Rules.pars_for(armed(), "high")["contact_cooldown_days"] == 1
      assert Rules.pars_for(armed(), "high")["protection_window_seconds"] == 86_400
      assert Rules.pars_for(armed(), "high")["carry_over_days"] == 3
    end
  end
end
