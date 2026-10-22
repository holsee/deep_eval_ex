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

  defmodule FailingMetric do
    @moduledoc false

    defstruct threshold: nil

    def metric_name, do: "FailingMetric"
    def default_threshold, do: 0.7

    def measure(_test_case, _opts), do: {:error, {:api_error, 500}}
  end

  defmodule ConfigurableMetric do
    @moduledoc false

    @default_threshold 0.5

    defstruct threshold: nil, label: nil

    def metric_name, do: "ConfigurableMetric"

    def measure(_test_case, opts) do
      threshold = Keyword.get(opts, :threshold, @default_threshold)
      label = Keyword.get(opts, :label, "default")

      {:ok,
       %Result{
         metric: metric_name(),
         score: 1.0,
         success: true,
         threshold: threshold,
         reason: label
       }}
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

    test "returns a flat list with one errored result per metric when a test case times out" do
      assert [results] = Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch], timeout: 20)

      assert [%Result{metric: "SlowMetric"}, %Result{metric: "ExactMatch"}] = results

      for result <- results do
        assert Result.errored?(result)
        assert result.success == false
        assert result.score == nil
        assert result.reason == nil
        assert result.error == "Evaluation timed out"
      end
    end

    test "timed-out results carry each metric's real threshold" do
      assert [[slow, exact]] =
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch], timeout: 20)

      # SlowMetric exposes no default threshold, so none is known.
      assert slow.threshold == nil
      assert exact.threshold == ExactMatch.default_threshold()
    end
  end

  describe "evaluate_metric/3 errors" do
    test "a metric returning {:error, reason} yields an errored result, not a failure" do
      result = Evaluator.evaluate_metric(test_case(), FailingMetric, [])

      assert %Result{
               metric: "FailingMetric",
               score: nil,
               success: false,
               reason: nil,
               error: "{:api_error, 500}",
               threshold: 0.7
             } = result

      assert Result.errored?(result)
    end

    test "missing parameters are reported as an error with the metric's threshold" do
      incomplete = %TestCase{input: "Q", actual_output: nil, expected_output: "A"}

      assert %Result{
               score: nil,
               success: false,
               error: "Missing required parameters: actual_output",
               threshold: 1.0
             } = Evaluator.evaluate_metric(incomplete, ExactMatch, [])
    end

    test "errored results use the run-level threshold over the metric default" do
      assert %Result{threshold: 0.3} =
               Evaluator.evaluate_metric(test_case(), FailingMetric, threshold: 0.3)
    end

    test "errored results use a metric struct's own threshold" do
      assert [[%Result{threshold: 0.9, error: "{:api_error, 500}"}]] =
               Evaluator.evaluate([test_case()], [%FailingMetric{threshold: 0.9}], threshold: 0.3)
    end
  end

  describe "evaluate_metric/3 with metric structs" do
    test "per-metric configuration overrides run-level options" do
      metric = %ConfigurableMetric{threshold: 0.9}

      assert [[%Result{threshold: 0.9}]] =
               Evaluator.evaluate([test_case()], [metric], threshold: 0.5)
    end

    test "run-level options apply when the metric leaves a field unset" do
      metric = %ConfigurableMetric{threshold: nil, label: "custom"}

      assert [[%Result{threshold: 0.7, reason: "custom"}]] =
               Evaluator.evaluate([test_case()], [metric], threshold: 0.7)
    end

    test "unset metric fields fall back to the metric's own default" do
      metric = %ConfigurableMetric{}

      assert %Result{threshold: 0.5, reason: "default"} =
               Evaluator.evaluate_metric(test_case(), metric, [])
    end
  end
end
