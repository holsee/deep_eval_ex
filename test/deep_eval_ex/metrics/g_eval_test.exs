defmodule DeepEvalEx.Metrics.GEvalTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.GEval
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "new/1" do
    test "creates GEval metric with criteria" do
      metric =
        GEval.new(
          name: "Helpfulness",
          criteria: "Is the response helpful?",
          evaluation_params: [:input, :actual_output]
        )

      assert metric.name == "Helpfulness"
      assert metric.criteria == "Is the response helpful?"
      assert metric.evaluation_params == [:input, :actual_output]
      assert metric.threshold == 0.5
      assert metric.score_range == {0, 10}
    end

    test "creates GEval metric with evaluation_steps" do
      metric =
        GEval.new(
          name: "Custom",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Step 1", "Step 2", "Step 3"]
        )

      assert metric.evaluation_steps == ["Step 1", "Step 2", "Step 3"]
      assert is_nil(metric.criteria)
    end

    test "creates GEval metric with rubric" do
      metric =
        GEval.new(
          name: "Quality",
          criteria: "Evaluate quality",
          evaluation_params: [:input, :actual_output],
          rubric: [
            {10, "Perfect"},
            {5, "Average"},
            {1, "Poor"}
          ]
        )

      assert metric.rubric == [{10, "Perfect"}, {5, "Average"}, {1, "Poor"}]
    end

    test "raises without criteria or evaluation_steps" do
      assert_raise ArgumentError, ~r/requires either :criteria or :evaluation_steps/, fn ->
        GEval.new(
          name: "Invalid",
          evaluation_params: [:input]
        )
      end
    end

    test "supports strict_mode" do
      metric =
        GEval.new(
          name: "Strict",
          criteria: "Binary check",
          evaluation_params: [:input],
          strict_mode: true
        )

      assert metric.strict_mode == true
    end

    test "strict_mode forces the threshold to the integer 1, as deepeval's constructor" do
      metric =
        GEval.new(
          name: "Strict",
          criteria: "Binary check",
          evaluation_params: [:input],
          strict_mode: true,
          threshold: 0.3
        )

      assert metric.threshold === 1
    end

    test "accepts a nil threshold for score-only evaluation and a flaky flag" do
      metric =
        GEval.new(
          name: "Scored",
          criteria: "Quality",
          evaluation_params: [:input],
          threshold: nil,
          flaky: true
        )

      assert metric.threshold == nil
      assert metric.flaky == true
      refute GEval.new(name: "D", criteria: "c", evaluation_params: [:input]).flaky
    end

    test "supports custom score_range" do
      metric =
        GEval.new(
          name: "Custom Range",
          criteria: "Test",
          evaluation_params: [:input],
          score_range: {1, 5}
        )

      assert metric.score_range == {1, 5}
    end
  end

  describe "metric_name/0" do
    test "returns GEval" do
      assert GEval.metric_name() == "GEval"
    end
  end

  describe "metric_name/1" do
    test "suffixes the configured name with [GEval] like deepeval's __name__" do
      metric = GEval.new(name: "Helpfulness", criteria: "c", evaluation_params: [:input])

      assert GEval.metric_name(metric) == "Helpfulness [GEval]"
    end

    test "returns the bare name when the suffix is disabled" do
      metric =
        GEval.new(
          name: "Helpfulness",
          criteria: "c",
          evaluation_params: [:input],
          include_g_eval_suffix: false
        )

      assert GEval.metric_name(metric) == "Helpfulness"
    end
  end

  describe "evaluate/2 with mock adapter" do
    test "evaluates test case with pre-defined steps" do
      # Mock the evaluation response
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 8, "reason" => "The response is helpful and accurate."}
      )

      metric =
        GEval.new(
          name: "Helpfulness",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: [
            "Check if the response addresses the question",
            "Verify the information is accurate",
            "Assess if the response is clear"
          ]
        )

      test_case =
        TestCase.new!(
          input: "How do I boil water?",
          actual_output: "Fill a pot with water, place on stove, heat until bubbles form."
        )

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # 8/10 normalized
      assert result.score == 0.8
      assert result.reason == "The response is helpful and accurate."
      assert result.metric == "Helpfulness [GEval]"
    end

    test "generates steps when not provided" do
      # Mock the steps generation
      Mock.set_schema_response(
        ~r/generate.*evaluation steps/i,
        %{"steps" => ["Step 1: Check accuracy", "Step 2: Check completeness"]}
      )

      # Mock the evaluation response
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 7, "reason" => "Good but could be more detailed."}
      )

      metric =
        GEval.new(
          name: "Accuracy",
          criteria: "Is the response accurate?",
          evaluation_params: [:input, :actual_output]
        )

      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4"
        )

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert result.score == 0.7

      assert result.metadata.evaluation_steps == [
               "Step 1: Check accuracy",
               "Step 2: Check completeness"
             ]
    end

    test "normalizes score to 0-1 range" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 5, "reason" => "Average response."}
      )

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          score_range: {0, 10}
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # 5/10 = 0.5
      assert result.score == 0.5
    end

    test "a nil threshold measures score-only, through the evaluator too" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 5, "reason" => "Average."})

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          threshold: nil,
          flaky: true
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, %{score: 0.5, threshold: nil, success: nil}} =
               GEval.evaluate(metric, test_case, adapter: :mock)

      assert %{score: 0.5, threshold: nil, success: nil, flaky: true} =
               DeepEvalEx.Evaluator.evaluate_metric(test_case, metric,
                 adapter: :mock,
                 threshold: 0.7
               )
    end

    test "handles custom score range" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 3, "reason" => "Meets expectations."}
      )

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          # 1-5 range
          score_range: {1, 5}
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # Score 3 in range 1-5: (3-1)/(5-1) = 2/4 = 0.5
      assert result.score == 0.5
    end

    test "returns error for missing evaluation params" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output, :expected_output],
          evaluation_steps: ["Check"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")
      # missing expected_output

      assert {:error, {:missing_params, [:expected_output]}} =
               GEval.evaluate(metric, test_case, adapter: :mock)
    end

    test "validates params as deepeval: an empty actual_output is rejected, other empties are not" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output, :expected_output],
          evaluation_steps: ["Check"]
        )

      assert {:error, {:empty_param, :actual_output}} =
               GEval.evaluate(
                 metric,
                 %TestCase{input: "Q", actual_output: "", expected_output: nil},
                 adapter: :mock
               )

      Mock.set_schema_response(~r/evaluator/i, %{"score" => 10, "reason" => "Fine."})

      assert {:ok, %{score: 1.0}} =
               GEval.evaluate(
                 metric,
                 %TestCase{input: "Q", actual_output: "A", expected_output: ""},
                 adapter: :mock
               )
    end

    test "does not accept context for retrieval_context" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:actual_output, :retrieval_context],
          evaluation_steps: ["Check"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A", context: ["ctx"])

      assert {:error, {:missing_params, [:retrieval_context]}} =
               GEval.evaluate(metric, test_case, adapter: :mock)
    end

    test "includes metadata in result" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 9, "reason" => "Excellent."}
      )

      metric =
        GEval.new(
          name: "Quality",
          criteria: "Is it good?",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Step 1"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert result.metadata.raw_score == 9
      assert result.metadata.score_range == {0, 10}
      assert result.metadata.evaluation_steps == ["Step 1"]
      assert result.metadata.criteria == "Is it good?"
    end
  end

  describe "do_measure/2" do
    test "works with inline configuration" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 8, "reason" => "Good."}
      )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} =
               GEval.do_measure(test_case,
                 name: "Inline",
                 criteria: "Is it good?",
                 evaluation_params: [:input, :actual_output],
                 evaluation_steps: ["Check"],
                 adapter: :mock
               )

      assert result.score == 0.8
      assert result.metric == "Inline [GEval]"
    end

    test "names the result with the bare name when the suffix is disabled" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 8, "reason" => "Good."})

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} =
               GEval.do_measure(test_case,
                 name: "Inline",
                 evaluation_params: [:input, :actual_output],
                 evaluation_steps: ["Check"],
                 include_g_eval_suffix: false,
                 adapter: :mock
               )

      assert result.metric == "Inline"
    end

    test "returns error without configuration" do
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:error, {:missing_config, _}} = GEval.do_measure(test_case, [])
    end
  end
end
