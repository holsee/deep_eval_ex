defmodule DeepEvalEx.EvaluatorTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Evaluator, Result, TestCase}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.{ExactMatch, Faithfulness, GEval, ToolCorrectness}
  alias DeepEvalEx.Schemas.ToolCall

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

  defmodule JudgeThenFailMetric do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "JudgeThenFail"

    @impl true
    def required_params, do: []

    # Two judge calls are paid for before the metric gives up, as when a
    # judge returns JSON that does not match the expected schema.
    def do_measure(_test_case, _opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 200))
      Usage.record(Usage.new("gpt-4o-mini", 500, 100))
      {:error, "judge returned invalid JSON"}
    end
  end

  defmodule RaisingJudge do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "RaisingJudge"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, _opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 200))
      raise ArgumentError, "judge returned invalid JSON"
    end
  end

  defmodule SlowJudge do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "SlowJudge"

    @impl true
    def required_params, do: []

    @impl true
    defdelegate evaluation_model(opts), to: DeepEvalEx.LLM.Adapter, as: :model_name

    def do_measure(_test_case, _opts), do: Process.sleep(:infinity)
  end

  defmodule ConfigurableMetric do
    @moduledoc false

    @default_threshold 0.5

    defstruct threshold: @default_threshold, label: nil

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

  describe "check_at_least_one_metric_has_threshold!/2" do
    @message "You must provide at least one non-flaky metric with a 'threshold', " <>
               "otherwise test cases can never pass or fail."

    test "passes when a non-flaky metric has a threshold" do
      assert :ok = Evaluator.check_at_least_one_metric_has_threshold!([ExactMatch], [])
      assert :ok = Evaluator.check_at_least_one_metric_has_threshold!([SlowMetric], [])

      assert :ok =
               Evaluator.check_at_least_one_metric_has_threshold!(
                 [%ConfigurableMetric{threshold: nil}, ExactMatch],
                 []
               )
    end

    test "counts strict mode as a threshold of 1" do
      assert :ok =
               Evaluator.check_at_least_one_metric_has_threshold!([ExactMatch],
                 threshold: nil,
                 strict_mode: true
               )
    end

    test "raises deepeval's ValueError message as an ArgumentError otherwise" do
      for {metrics, opts} <- [
            {[ExactMatch], [threshold: nil]},
            {[%ConfigurableMetric{threshold: nil}], []},
            {[ExactMatch], [flaky: true]},
            {[SlowMetric], [threshold: nil]}
          ] do
        assert_raise ArgumentError, @message, fn ->
          Evaluator.check_at_least_one_metric_has_threshold!(metrics, opts)
        end
      end
    end
  end

  describe "evaluate_with_durations/3" do
    test "returns each test case's duration in seconds alongside its results" do
      assert {[[%Result{metric: "SleepMetric"}], [%Result{metric: "SleepMetric"}]], durations} =
               Evaluator.evaluate_with_durations(
                 [test_case(), test_case()],
                 [%SleepMetric{sleep: 50}]
               )

      for duration <- durations do
        assert is_float(duration) and duration >= 0.05
      end
    end

    test "reports a timed-out test case as having taken its timeout" do
      assert {[[%Result{error: "Evaluation timed out"}]], [0.02]} =
               Evaluator.evaluate_with_durations([test_case()], [SlowMetric],
                 timeout: 20,
                 metric_timeout: :infinity
               )
    end
  end

  describe "evaluate/3" do
    test "returns one flat result list per test case" do
      assert [[%Result{metric: "Exact Match", success: true}]] =
               Evaluator.evaluate([test_case()], [ExactMatch])
    end

    test "returns a flat list with one errored result per metric when a test case times out" do
      # Without a per-metric bound only the per-test-case timeout applies.
      assert [results] =
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch],
                 timeout: 20,
                 metric_timeout: :infinity
               )

      assert [%Result{metric: "SlowMetric"}, %Result{metric: "Exact Match"}] = results

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

      assert_receive {:metric_stop, "Exact Match"}
      assert_receive {:metric_stop, "Exact Match"}
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
               threshold: 1
             } = Evaluator.evaluate_metric(incomplete, ExactMatch, [])
    end

    test "errored results use the run-level threshold over the metric default" do
      assert %Result{threshold: 0.3} =
               Evaluator.evaluate_metric(test_case(), FailingMetric, threshold: 0.3)
    end

    test "errored GEval results carry the configured [GEval] name" do
      metric =
        GEval.new(
          name: "Correctness",
          criteria: "Is it correct?",
          evaluation_params: [:input, :actual_output, :expected_output],
          threshold: 0.6
        )

      incomplete = %TestCase{input: "Q", actual_output: "A", expected_output: nil}

      assert %Result{metric: "Correctness [GEval]", threshold: 0.6, score: nil} =
               result = Evaluator.evaluate_metric(incomplete, metric, [])

      assert Result.errored?(result)
    end

    test "errored GEval results use the bare name when the suffix is disabled" do
      metric =
        GEval.new(
          name: "Correctness",
          criteria: "Is it correct?",
          evaluation_params: [:expected_output],
          include_g_eval_suffix: false
        )

      incomplete = %TestCase{input: "Q", actual_output: "A", expected_output: nil}

      assert %Result{metric: "Correctness"} = Evaluator.evaluate_metric(incomplete, metric, [])
    end

    test "errored results carry the forced strict threshold, strict mode and flakiness" do
      assert [[%Result{threshold: 1, strict_mode: true, flaky: true, success: false}]] =
               Evaluator.evaluate([test_case()], [FailingMetric],
                 strict_mode: true,
                 flaky: true,
                 threshold: 0.3
               )
    end

    test "errored score-only results have no success, as deepeval's is_successful" do
      assert [[%Result{threshold: nil, success: nil, error: "{:api_error, 500}"}]] =
               Evaluator.evaluate([test_case()], [%FailingMetric{threshold: nil}])
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
      metric = %ConfigurableMetric{threshold: 0.9, label: nil}

      assert [[%Result{threshold: 0.9, reason: "run"}]] =
               Evaluator.evaluate([test_case()], [metric], label: "run")
    end

    test "a metric struct's nil threshold is score-only, not unset" do
      metric = %ConfigurableMetric{threshold: nil}

      assert [[%Result{threshold: nil}]] =
               Evaluator.evaluate([test_case()], [metric], threshold: 0.7)
    end

    test "unset metric fields fall back to the metric's own default" do
      metric = %ConfigurableMetric{}

      assert %Result{threshold: 0.5, reason: "default"} =
               Evaluator.evaluate_metric(test_case(), metric, [])
    end
  end

  describe "evaluate_metric/3 usage on errored results" do
    test "an errored result keeps the model, tokens and cost of the judge calls made" do
      result = Evaluator.evaluate_metric(test_case(), JudgeThenFailMetric, [])

      assert %Result{
               error: "judge returned invalid JSON",
               score: nil,
               evaluation_model: "gpt-4o-mini",
               input_tokens: 1_500,
               output_tokens: 300
             } = result

      assert_in_delta result.evaluation_cost, (1_500 * 0.15 + 300 * 0.60) / 1_000_000, 1.0e-12
    end

    test "an errored LLM metric reports its configured judge model without any call" do
      incomplete = %TestCase{input: "Q", actual_output: "A"}

      assert %Result{evaluation_model: "mock-model", input_tokens: nil, evaluation_cost: nil} =
               result = Evaluator.evaluate_metric(incomplete, Faithfulness, adapter: :mock)

      assert Result.errored?(result)

      assert %Result{evaluation_model: "gpt-4o"} =
               Evaluator.evaluate_metric(incomplete, Faithfulness,
                 adapter: :openai,
                 model: "gpt-4o"
               )
    end

    test "an errored GEval reports the judge model it is configured with" do
      metric =
        GEval.new(
          name: "Correctness",
          criteria: "Is it correct?",
          evaluation_params: [:expected_output],
          model: {:openai, "gpt-4.1"}
        )

      incomplete = %TestCase{input: "Q", actual_output: "A"}

      assert %Result{evaluation_model: "gpt-4.1"} =
               Evaluator.evaluate_metric(incomplete, metric, adapter: :mock)
    end

    test "metrics that call no LLM report no judge model" do
      incomplete = %TestCase{input: "Q", actual_output: nil, expected_output: "A"}

      assert %Result{evaluation_model: nil} =
               Evaluator.evaluate_metric(incomplete, ExactMatch, adapter: :mock)
    end

    test "ToolCorrectness reports its judge model with or without available_tools" do
      incomplete = %TestCase{input: "Q", actual_output: "A", tools_called: nil}
      tools = [%ToolCall{name: "search"}]

      for opts <- [[], [available_tools: tools]] do
        assert %Result{evaluation_model: "mock-model"} =
                 result =
                 Evaluator.evaluate_metric(incomplete, ToolCorrectness, [adapter: :mock] ++ opts)

        assert Result.errored?(result)
      end
    end

    test "a timed-out LLM metric still reports its configured judge model" do
      assert [%Result{error: "Metric timed out", evaluation_model: "mock-model"}] =
               Evaluator.evaluate_single(test_case(), [SlowJudge],
                 adapter: :mock,
                 metric_timeout: 50
               )
    end
  end

  describe "evaluate_metric/3 with a metric that raises" do
    test "records the exception's message as the error, as deepeval records str(e)" do
      result = Evaluator.evaluate_metric(test_case(), RaisingJudge, threshold: 0.6)

      assert %Result{
               metric: "RaisingJudge",
               score: nil,
               success: false,
               threshold: 0.6,
               error: "judge returned invalid JSON"
             } = result
    end

    test "keeps the usage of the judge calls made before the exception" do
      assert %Result{evaluation_model: "gpt-4o-mini", input_tokens: 1_000, output_tokens: 200} =
               Evaluator.evaluate_metric(test_case(), RaisingJudge, [])
    end

    test "errors only the raising metric of a test case" do
      assert [[%Result{error: "judge returned invalid JSON"}, %Result{score: 1.0}]] =
               Evaluator.evaluate([test_case()], [RaisingJudge, ExactMatch])
    end
  end
end
