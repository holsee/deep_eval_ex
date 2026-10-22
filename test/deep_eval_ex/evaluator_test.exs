defmodule DeepEvalEx.EvaluatorTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Evaluator, Result, TestCase}
  alias DeepEvalEx.Metrics.ExactMatch

  defmodule SlowMetric do
    @moduledoc false

    def metric_name, do: "SlowMetric"

    def measure(_test_case, _opts) do
      Process.sleep(1_000)
      {:ok, %Result{metric: metric_name(), score: 1.0, success: true, threshold: 0.5}}
    end
  end

  defp test_case do
    TestCase.new!(input: "What is 2 + 2?", actual_output: "4", expected_output: "4")
  end

  describe "evaluate/3" do
    test "returns one flat result list per test case" do
      assert [[%Result{metric: "ExactMatch", success: true}]] =
               Evaluator.evaluate([test_case()], [ExactMatch])
    end

    test "returns a flat list with one error result per metric when a test case times out" do
      assert [results] = Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch], timeout: 20)

      assert [%Result{metric: "SlowMetric"}, %Result{metric: "ExactMatch"}] = results

      for result <- results do
        assert result.success == false
        assert result.score == 0.0
        assert result.reason == "Evaluation timed out"
      end
    end
  end
end
