# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.JsonCorrectnessTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.JsonCorrectness
  alias DeepEvalEx.Prompts.JsonCorrectness, as: Template
  alias DeepEvalEx.SystemOne.Error
  alias DeepEvalEx.Test.SystemOneStub
  alias DeepEvalEx.TestCase

  @moduletag :capture_log

  @reason_prompt ~r/give a reason why it is OR is not a valid Json/
  @correct_reason "The generated Json matches and is syntactically correct to the expected schema."

  @schema ~S"""
  {
    "properties": {
      "name": {"title": "Name", "type": "string"},
      "age": {"title": "Age", "type": "integer"}
    },
    "required": ["name", "age"],
    "title": "Person",
    "type": "object"
  }
  """

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case(actual_output),
    do: TestCase.new!(input: "Return the profile as JSON.", actual_output: actual_output)

  # A System One model that must be neither built nor asked: deepeval's
  # JsonCorrectness never initialises one.
  defp unusable_system_one do
    {SystemOneStub,
     init: {:error, %Error{reason: :auth, type: "AuthenticationError", message: "no key"}},
     decide: fn _state, _questions, _opts -> flunk("System One was asked") end}
  end

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's" do
      assert JsonCorrectness.metric_name() == "Json Correctness"
      assert JsonCorrectness.required_params() == [:input, :actual_output]
    end
  end

  describe "measure/2" do
    test "scores the integer 1 with deepeval's reason and no judge call for a matching output" do
      assert {:ok, result} =
               JsonCorrectness.measure(test_case(~s({"name": "Ana", "age": 30, "x": []})),
                 adapter: :mock,
                 expected_schema: @schema
               )

      assert result.metric == "Json Correctness"
      assert result.score === 1
      assert result.success == true
      assert result.reason == @correct_reason
      assert result.verbose_logs == ~s(LLM outputed Json:\n{"name": "Ana", "age": 30, "x": []})
      assert Mock.get_recorded_prompts() == []
    end

    test "is strict by default: the threshold is the integer 1" do
      assert {:ok, result} =
               JsonCorrectness.measure(test_case(~s({"name": "Ana", "age": 30})),
                 adapter: :mock,
                 expected_schema: @schema,
                 threshold: 0.3
               )

      assert result.threshold === 1
      assert result.strict_mode == true
    end

    test "scores the integer 0 and asks the judge for the reason when the output fails the schema" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The generated Json is not valid."})

      output = ~s({"name": "Ana", "age": "thirty"})

      assert {:ok, result} =
               JsonCorrectness.measure(test_case(output),
                 adapter: :mock,
                 expected_schema: @schema
               )

      assert result.score === 0
      assert result.success == false
      assert result.reason == "The generated Json is not valid."

      assert [prompt] = Mock.get_recorded_prompts()

      assert prompt =~
               "Generated Json:\n#{output}\n\nExpected Json Schema:\n{\n    \"properties\""

      assert prompt =~ "Is Valid Json?\nFalse\n\nJSON:"
    end

    test "scores output that is not JSON at all 0" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "Not JSON."})

      assert {:ok, result} =
               JsonCorrectness.measure(test_case("Sure! Here it is."),
                 adapter: :mock,
                 expected_schema: @schema
               )

      assert result.score === 0
      assert result.reason == "Not JSON."
    end

    test "with strict_mode off uses the 0.5 threshold, and include_reason off makes no call" do
      assert {:ok, result} =
               JsonCorrectness.measure(test_case("[]"),
                 adapter: :mock,
                 expected_schema: @schema,
                 strict_mode: false,
                 include_reason: false
               )

      assert result.threshold == 0.5
      assert result.strict_mode == false
      assert result.score === 0
      assert result.success == false
      assert result.reason == nil
      assert Mock.get_recorded_prompts() == []
    end

    test "accepts the schema as a map with atom keys" do
      schema = %{type: "object", properties: %{n: %{type: "integer"}}, required: [:n]}

      assert {:ok, %{score: 0}} =
               JsonCorrectness.measure(test_case(~s({"n": "1"})),
                 adapter: :mock,
                 expected_schema: schema,
                 include_reason: false
               )
    end

    test "raises ArgumentError without an expected schema, as deepeval's constructor requires one" do
      assert_raise ArgumentError, ~r/requires an :expected_schema/, fn ->
        JsonCorrectness.measure(test_case("{}"), adapter: :mock)
      end

      assert_raise ArgumentError, ~r/not valid JSON/, fn ->
        JsonCorrectness.measure(test_case("{}"), adapter: :mock, expected_schema: "{")
      end
    end
  end

  describe "eval modes" do
    test "has no whole-metric System One request" do
      assert JsonCorrectness.system_one_eval_spec(test_case("{}"), []) == nil
    end

    test "under :system_one calls no LLM and no System One model; the reason is the validation error" do
      assert {:ok, result} =
               JsonCorrectness.measure(test_case(~s({"name": "Ana"})),
                 adapter: :mock,
                 expected_schema: @schema,
                 eval_mode: :system_one,
                 system_one_model: unusable_system_one()
               )

      assert result.score === 0
      assert result.reason == "1 validation error for Person\nage\n  Field required"
      assert result.evaluation_model == nil
      assert result.evaluation_cost == 0.0
      assert Mock.get_recorded_prompts() == []
    end

    test "under :system_one a matching output keeps deepeval's reason" do
      assert {:ok, result} =
               JsonCorrectness.measure(test_case(~s({"name": "Ana", "age": 1})),
                 adapter: :mock,
                 expected_schema: @schema,
                 eval_mode: :system_one,
                 system_one_model: unusable_system_one()
               )

      assert result.score === 1
      assert result.reason == @correct_reason
    end

    test "under :hybrid the judge writes the reason and no System One model is built" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "Missing age."})

      assert {:ok, result} =
               JsonCorrectness.measure(test_case(~s({"name": "Ana"})),
                 adapter: :mock,
                 expected_schema: @schema,
                 eval_mode: :hybrid,
                 system_one_model: unusable_system_one()
               )

      assert result.reason == "Missing age."
      assert result.evaluation_model == "mock-model"
      assert result.system_one_fallback_reason == nil
    end
  end

  describe "new/1" do
    test "builds a strict metric by default, its schema normalised" do
      metric = JsonCorrectness.new(expected_schema: @schema)

      assert %JsonCorrectness{
               strict_mode: true,
               threshold: 1,
               expected_schema: %Jason.OrderedObject{}
             } =
               metric

      assert %JsonCorrectness{strict_mode: false, threshold: 0.7} =
               JsonCorrectness.new(expected_schema: @schema, strict_mode: false, threshold: 0.7)
    end

    test "raises ArgumentError without an expected schema" do
      assert_raise ArgumentError, ~r/requires an :expected_schema/, fn ->
        JsonCorrectness.new([])
      end
    end

    test "evaluates as a struct, exporting deepeval's strict mode" do
      metric = JsonCorrectness.new(expected_schema: @schema)

      assert [[result]] =
               DeepEvalEx.Evaluator.evaluate([test_case(~s({"name": "Ana", "age": 1}))], [metric],
                 adapter: :mock
               )

      assert result.score === 1
      assert result.threshold === 1
      assert result.strict_mode == true
    end

    test "a missing param errors with the strict threshold" do
      metric = JsonCorrectness.new(expected_schema: @schema)
      test_case = %TestCase{input: "Q", actual_output: nil}

      assert [[result]] =
               DeepEvalEx.Evaluator.evaluate([test_case], [metric],
                 adapter: :mock,
                 ignore_errors: true
               )

      assert result.error =~ "actual_output"
      assert result.threshold === 1
      assert result.strict_mode == true
    end
  end

  describe "as a module in evaluate/3" do
    test "keeps its strict default" do
      assert [[result]] =
               DeepEvalEx.Evaluator.evaluate(
                 [test_case(~s({"name": "Ana", "age": 1}))],
                 [JsonCorrectness],
                 adapter: :mock,
                 expected_schema: @schema
               )

      assert result.threshold === 1
      assert result.strict_mode == true
    end
  end

  describe "Prompts.JsonCorrectness.generate_reason/1" do
    test "prints the schema as json.dumps(indent=4) and the validity as a Python bool" do
      prompt =
        Template.generate_reason(
          actual_output: "{}",
          expected_schema: %{"type" => "object", "title" => "Café"},
          is_valid_json: false
        )

      assert prompt =~
               "Expected Json Schema:\n{\n    \"title\": \"Caf\\u00e9\",\n    \"type\": \"object\"\n}\n\nIs Valid Json?\nFalse"
    end
  end
end
