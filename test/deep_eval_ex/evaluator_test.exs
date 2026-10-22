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

  defmodule SleepMetric do
    @moduledoc false

    defstruct sleep: 0, label: nil

    def metric_name, do: "SleepMetric"

    def measure(_test_case, opts) do
      Process.sleep(Keyword.fetch!(opts, :sleep))

      {:ok,
       %Result{
         metric: metric_name(),
         score: 1.0,
         success: true,
         threshold: 0.5,
         reason: Keyword.get(opts, :label)
       }}
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

  def forward_metric_stop(_event, _measurements, metadata, {parent, name}) do
    if metadata.test_case_id == name, do: send(parent, {:metric_stop, metadata.metric})
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
      # Without a per-metric bound only the per-test-case timeout applies.
      assert [results] =
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch],
                 timeout: 20,
                 metric_timeout: :infinity
               )

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
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch],
                 timeout: 20,
                 metric_timeout: :infinity
               )

      # SlowMetric exposes no default threshold, so none is known.
      assert slow.threshold == nil
      assert exact.threshold == ExactMatch.default_threshold()
    end
  end

  describe "evaluate_single/3 concurrency" do
    test "preserves metric order when metrics finish out of order" do
      metrics = [
        %SleepMetric{sleep: 150, label: "first"},
        %SleepMetric{sleep: 10, label: "second"},
        %SleepMetric{sleep: 80, label: "third"}
      ]

      results = Evaluator.evaluate_single(test_case(), metrics)

      assert Enum.map(results, & &1.reason) == ["first", "second", "third"]
    end

    test "runs metrics concurrently, so wall time tracks the slowest metric" do
      metrics = for i <- 1..5, do: %SleepMetric{sleep: 200, label: "m#{i}"}

      {elapsed_us, results} =
        :timer.tc(fn -> Evaluator.evaluate_single(test_case(), metrics) end)

      assert length(results) == 5
      assert Enum.all?(results, & &1.success)
      # Sequential execution would take at least 1_000ms.
      assert div(elapsed_us, 1_000) < 700
    end

    test ":metric_concurrency bounds how many metrics run at once" do
      metrics = for i <- 1..3, do: %SleepMetric{sleep: 100, label: "m#{i}"}

      {elapsed_us, results} =
        :timer.tc(fn ->
          Evaluator.evaluate_single(test_case(), metrics, metric_concurrency: 1)
        end)

      assert Enum.map(results, & &1.reason) == ["m1", "m2", "m3"]
      assert div(elapsed_us, 1_000) >= 300
    end

    test "a slow metric errors alone while its siblings succeed" do
      metrics = [%SleepMetric{sleep: 2_000, label: "slow"}, ExactMatch]

      assert [slow, exact] =
               Evaluator.evaluate_single(test_case(), metrics, metric_timeout: 50)

      assert Result.errored?(slow)
      assert slow.metric == "SleepMetric"
      assert slow.error == "Metric timed out"
      assert exact.success
      refute Result.errored?(exact)
    end

    test "per-metric timeout defaults to :timeout and fires before the test case's" do
      assert [[slow, exact]] =
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch], timeout: 50)

      assert slow.error == "Metric timed out"
      assert exact.success
    end

    test "the test case timeout covers metrics queued behind :metric_concurrency" do
      metrics = for i <- 1..3, do: %SleepMetric{sleep: 100, label: "m#{i}"}

      # Each metric fits its 250ms budget; the case as a whole takes ~300ms.
      assert [results] =
               Evaluator.evaluate([test_case()], metrics, timeout: 250, metric_concurrency: 1)

      assert Enum.all?(results, & &1.success)
    end

    test "metric telemetry events still fire for every metric" do
      name = "telemetry-#{System.unique_integer([:positive])}"
      parent = self()
      handler_id = {__MODULE__, name}

      :telemetry.attach(
        handler_id,
        [:deep_eval_ex, :metric, :stop],
        &__MODULE__.forward_metric_stop/4,
        {parent, name}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      test_case = %{test_case() | name: name}
      Evaluator.evaluate_single(test_case, [ExactMatch, ExactMatch])

      assert_receive {:metric_stop, "ExactMatch"}
      assert_receive {:metric_stop, "ExactMatch"}
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
