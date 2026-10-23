defmodule DeepEvalEx.ConversationSimulator.TemplatesTest do
  @moduledoc """
  Renders the simulator templates for the arguments in
  test/fixtures/deepeval/simulator/templates.json and compares them, byte
  for byte, with the prompts deepeval 4.3.1's templates rendered for the
  same arguments (written by scripts/parity/generate_simulator_fixtures.py).
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationSimulator.{
    SimulationGraphTemplate,
    SimulationTemplate,
    SimulatorControllerTemplate
  }

  alias DeepEvalEx.Dataset.ConversationalGolden
  alias DeepEvalEx.Turn

  @fixture Path.expand("../../fixtures/deepeval/simulator/templates.json", __DIR__)
  @external_resource @fixture

  @modules %{
    "SimulationTemplate" => SimulationTemplate,
    "SimulatorControllerTemplate" => SimulatorControllerTemplate,
    "SimulationGraphTemplate" => SimulationGraphTemplate
  }

  # Each template's parameters, in deepeval's order.
  @parameters %{
    "simulate_first_user_turn" => ~w(golden language),
    "simulate_user_turn" => ~w(golden turns language),
    "check_expected_outcome" => ~w(previous_conversation expected_outcome),
    "classify_edge" => ~w(assistant_reply choices)
  }

  for {entry, index} <- @fixture |> File.read!() |> Jason.decode!() |> Enum.with_index() do
    @entry entry

    test "##{index} #{entry["template"]} renders deepeval's prompt" do
      [class, method] = String.split(@entry["template"], ".")
      args = Enum.map(Map.fetch!(@parameters, method), &arg(&1, Map.fetch!(@entry["args"], &1)))

      assert apply(Map.fetch!(@modules, class), String.to_atom(method), args) ==
               @entry["prompt"]
    end
  end

  test "every template function is covered by the fixture" do
    covered =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> MapSet.new(& &1["template"])

    for {class, module} <- @modules,
        {name, _arity} <- module.__info__(:functions),
        Map.has_key?(@parameters, Atom.to_string(name)) do
      assert "#{class}.#{name}" in covered
    end
  end

  defp arg("golden", golden), do: ConversationalGolden.new!(golden)
  defp arg("turns", turns), do: Enum.map(turns, &Turn.new!/1)
  defp arg(_name, value), do: value
end
