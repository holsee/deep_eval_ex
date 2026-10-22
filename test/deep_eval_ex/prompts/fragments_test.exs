defmodule DeepEvalEx.Prompts.FragmentsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Prompts.Fragments

  doctest Fragments

  test "multimodal_input_rules_turn_metric/1 is the turn metrics' rules between newlines" do
    rules = Fragments.multimodal_input_rules_turn_metric(multimodal: true)

    assert rules =~ ~r/\A\n--- MULTIMODAL INPUT RULES ---\n/
    assert String.ends_with?(rules, "respond with 'borderline'.\n")
  end
end
