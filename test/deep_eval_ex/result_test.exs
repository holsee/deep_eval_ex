defmodule DeepEvalEx.ResultTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Result

  describe "new/1" do
    test "builds a scored result that is not errored" do
      result = Result.new(metric: "GEval", score: 0.8, threshold: 0.5, reason: "Good.")

      assert %Result{score: 0.8, success: true, threshold: 0.5, error: nil} = result
      refute Result.errored?(result)
    end

    test "keeps the evaluation model and token counts when given" do
      result =
        Result.new(
          metric: "GEval",
          score: 0.8,
          evaluation_model: "gpt-4o",
          input_tokens: 10,
          output_tokens: 5,
          evaluation_cost: 0.0001
        )

      assert %Result{
               evaluation_model: "gpt-4o",
               input_tokens: 10,
               output_tokens: 5,
               evaluation_cost: 0.0001
             } = result
    end
  end

  describe "error/3" do
    test "stores an exception as its message, as deepeval stores str(exception)" do
      result =
        Result.error("Faithfulness", %ArgumentError{message: "judge returned invalid JSON"})

      assert result.error == "judge returned invalid JSON"
    end

    test "builds an errored result with no score and success false" do
      result = Result.error("Faithfulness", "Rate limit exceeded", threshold: 0.7)

      assert %Result{
               metric: "Faithfulness",
               score: nil,
               success: false,
               reason: nil,
               threshold: 0.7,
               error: "Rate limit exceeded"
             } = result

      assert Result.errored?(result)
      refute Result.success?(result)
    end

    test "leaves the threshold nil when it is not known" do
      assert %Result{threshold: nil} = Result.error("Custom", "boom")
    end

    test "formats missing parameter errors" do
      result = Result.error("ExactMatch", {:missing_params, [:actual_output, :expected_output]})

      assert result.error == "Missing required parameters: actual_output, expected_output"
    end

    test "inspects non-string error terms" do
      assert Result.error("GEval", {:api_error, 429}).error == "{:api_error, 429}"
    end

    test "keeps evaluation cost and latency when given" do
      result = Result.error("GEval", "boom", evaluation_cost: 0.01, latency_ms: 12)

      assert %Result{evaluation_cost: 0.01, latency_ms: 12} = result
    end

    test "keeps the evaluation model and token counts when given" do
      result = Result.error("GEval", "boom", evaluation_model: "gpt-4o", input_tokens: 3)

      assert %Result{evaluation_model: "gpt-4o", input_tokens: 3, output_tokens: nil} = result
    end
  end

  describe "summary/1" do
    test "reports PASS or FAIL with the score for scored results" do
      result = Result.new(metric: "GEval", score: 0.25, threshold: 0.5, reason: "Weak.")

      assert Result.summary(result) == "GEval: FAIL (25.0%) - Weak."
    end

    test "accepts an integer score, as deepeval's QAG scoring returns for no verdicts" do
      result = Result.new(metric: "Faithfulness", score: 1, threshold: 0.5)

      assert Result.summary(result) == "Faithfulness: PASS (100.0%)"
    end

    test "reports ERROR with the message for errored results" do
      result = Result.error("GEval", "Evaluation timed out", threshold: 0.5)

      assert Result.summary(result) == "GEval: ERROR - Evaluation timed out"
      assert to_string(result) == "GEval: ERROR - Evaluation timed out"
    end
  end

  describe "Inspect" do
    test "shows the ERROR status and message for errored results" do
      inspected = inspect(Result.error("GEval", "Evaluation timed out", threshold: 0.5))

      assert inspected =~ ~s(status: "ERROR")
      assert inspected =~ ~s(error: "Evaluation timed out")
      assert inspected =~ "score: nil"
      refute inspected =~ "FAIL"
    end

    test "shows PASS or FAIL for scored results" do
      inspected = inspect(Result.new(metric: "GEval", score: 0.9, threshold: 0.5))

      assert inspected =~ ~s(status: "PASS")
      refute inspected =~ "error:"
    end
  end
end
