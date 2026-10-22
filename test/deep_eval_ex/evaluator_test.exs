defmodule DeepEvalEx.EvaluatorTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Evaluator, MetricError, MissingTestCaseParamsError, Result, TestCase}
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

  # Reports to `pid` how many probes are running when it starts, and when.
  defmodule ProbeMetric do
    @moduledoc false

    defstruct pid: nil, running: nil, sleep: 50, label: nil

    def metric_name, do: "ProbeMetric"

    def measure(_test_case, opts) do
      running = Keyword.fetch!(opts, :running)
      level = :atomics.add_get(running, 1, 1)
      send(Keyword.fetch!(opts, :pid), {:probe, Keyword.get(opts, :label), level, now()})
      Process.sleep(Keyword.fetch!(opts, :sleep))
      :atomics.sub(running, 1, 1)
      {:ok, %Result{metric: metric_name(), score: 1.0, success: true, threshold: 0.5}}
    end

    defp now, do: System.monotonic_time(:millisecond)
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

  defmodule ScoredMetric do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    defstruct []

    @impl true
    def metric_name, do: "Scored"

    @impl true
    def required_params, do: [:input]

    def do_measure(_test_case, opts) do
      {:ok,
       Result.new(metric: metric_name(), score: 1.0, threshold: Keyword.get(opts, :threshold))}
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
                 metric_timeout: :infinity,
                 ignore_errors: true
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
                 metric_timeout: :infinity,
                 ignore_errors: true
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
                 metric_timeout: :infinity,
                 ignore_errors: true
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
               Evaluator.evaluate_single(test_case(), metrics,
                 metric_timeout: 50,
                 ignore_errors: true
               )

      assert Result.errored?(slow)
      assert slow.metric == "SleepMetric"
      assert slow.error == "Metric timed out"
      assert exact.success
      refute Result.errored?(exact)
    end

    test "per-metric timeout defaults to :timeout and fires before the test case's" do
      assert [[slow, exact]] =
               Evaluator.evaluate([test_case()], [SlowMetric, ExactMatch],
                 timeout: 50,
                 ignore_errors: true
               )

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

  describe "evaluate_metric/3 errors with ignore_errors: true" do
    test "a metric returning {:error, reason} yields an errored result, not a failure" do
      result = Evaluator.evaluate_metric(test_case(), FailingMetric, ignore_errors: true)

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
               error: "'actual_output' cannot be None for the 'Exact Match' metric",
               threshold: 1
             } = Evaluator.evaluate_metric(incomplete, ExactMatch, ignore_errors: true)
    end

    test "errored results use the run-level threshold over the metric default" do
      assert %Result{threshold: 0.3} =
               Evaluator.evaluate_metric(test_case(), FailingMetric,
                 threshold: 0.3,
                 ignore_errors: true
               )
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
               result = Evaluator.evaluate_metric(incomplete, metric, ignore_errors: true)

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

      assert %Result{metric: "Correctness"} =
               Evaluator.evaluate_metric(incomplete, metric, ignore_errors: true)
    end

    test "errored results carry the forced strict threshold, strict mode and flakiness" do
      assert [[%Result{threshold: 1, strict_mode: true, flaky: true, success: false}]] =
               Evaluator.evaluate([test_case()], [FailingMetric],
                 strict_mode: true,
                 flaky: true,
                 threshold: 0.3,
                 ignore_errors: true
               )
    end

    test "errored score-only results have no success, as deepeval's is_successful" do
      assert [[%Result{threshold: nil, success: nil, error: "{:api_error, 500}"}]] =
               Evaluator.evaluate([test_case()], [%FailingMetric{threshold: nil}],
                 ignore_errors: true
               )
    end

    test "errored results use a metric struct's own threshold" do
      assert [[%Result{threshold: 0.9, error: "{:api_error, 500}"}]] =
               Evaluator.evaluate([test_case()], [%FailingMetric{threshold: 0.9}],
                 threshold: 0.3,
                 ignore_errors: true
               )
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
      result = Evaluator.evaluate_metric(test_case(), JudgeThenFailMetric, ignore_errors: true)

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
               result =
               Evaluator.evaluate_metric(incomplete, Faithfulness,
                 adapter: :mock,
                 ignore_errors: true
               )

      assert Result.errored?(result)

      assert %Result{evaluation_model: "gpt-4o"} =
               Evaluator.evaluate_metric(incomplete, Faithfulness,
                 adapter: :openai,
                 model: "gpt-4o",
                 ignore_errors: true
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
               Evaluator.evaluate_metric(incomplete, metric, adapter: :mock, ignore_errors: true)
    end

    test "metrics that call no LLM report no judge model" do
      incomplete = %TestCase{input: "Q", actual_output: nil, expected_output: "A"}

      assert %Result{evaluation_model: nil} =
               Evaluator.evaluate_metric(incomplete, ExactMatch,
                 adapter: :mock,
                 ignore_errors: true
               )
    end

    test "ToolCorrectness reports its judge model with or without available_tools" do
      incomplete = %TestCase{input: "Q", actual_output: "A", tools_called: nil}
      tools = [%ToolCall{name: "search"}]

      for opts <- [[], [available_tools: tools]] do
        assert %Result{evaluation_model: "mock-model"} =
                 result =
                 Evaluator.evaluate_metric(
                   incomplete,
                   ToolCorrectness,
                   [adapter: :mock, ignore_errors: true] ++ opts
                 )

        assert Result.errored?(result)
      end
    end

    test "a timed-out LLM metric still reports its configured judge model" do
      assert [%Result{error: "Metric timed out", evaluation_model: "mock-model"}] =
               Evaluator.evaluate_single(test_case(), [SlowJudge],
                 adapter: :mock,
                 metric_timeout: 50,
                 ignore_errors: true
               )
    end
  end

  describe "evaluate_metric/3 with a metric that raises, with ignore_errors: true" do
    test "records the exception's message as the error, as deepeval records str(e)" do
      result =
        Evaluator.evaluate_metric(test_case(), RaisingJudge, threshold: 0.6, ignore_errors: true)

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
               Evaluator.evaluate_metric(test_case(), RaisingJudge, ignore_errors: true)
    end

    test "errors only the raising metric of a test case" do
      assert [[%Result{error: "judge returned invalid JSON"}, %Result{score: 1.0}]] =
               Evaluator.evaluate([test_case()], [RaisingJudge, ExactMatch], ignore_errors: true)
    end
  end

  describe "ignore_errors: false (the default, as deepeval's ErrorConfig)" do
    test "raises a MetricError for a metric returning {:error, reason}" do
      error =
        assert_raise MetricError, "{:api_error, 500}", fn ->
          Evaluator.evaluate_metric(test_case(), FailingMetric, [])
        end

      assert %MetricError{metric: "FailingMetric", reason: {:api_error, 500}} = error
    end

    test "the MetricError carries the metric's state, with success nil as measure() leaves it" do
      error =
        assert_raise MetricError, fn ->
          Evaluator.evaluate_metric(test_case(), JudgeThenFailMetric, threshold: 0.6)
        end

      assert %Result{
               metric: "JudgeThenFail",
               score: nil,
               success: nil,
               threshold: 0.6,
               error: "judge returned invalid JSON",
               evaluation_model: "gpt-4o-mini",
               input_tokens: 1_500,
               output_tokens: 300
             } = error.result
    end

    test "re-raises the exception a metric raised" do
      assert_raise ArgumentError, "judge returned invalid JSON", fn ->
        Evaluator.evaluate_metric(test_case(), RaisingJudge, [])
      end
    end

    test "raises deepeval's MissingTestCaseParamsError for missing params" do
      incomplete = %TestCase{input: "Q", actual_output: nil, expected_output: "A"}

      error =
        assert_raise MissingTestCaseParamsError,
                     "'actual_output' cannot be None for the 'Exact Match' metric",
                     fn -> Evaluator.evaluate_metric(incomplete, ExactMatch, []) end

      assert %MissingTestCaseParamsError{
               metric: "Exact Match",
               reason: {:missing_params, [:actual_output]},
               result: %Result{success: nil, threshold: 1}
             } = error
    end

    test "propagates out of evaluate/3 from a concurrently run metric" do
      assert_raise ArgumentError, "judge returned invalid JSON", fn ->
        Evaluator.evaluate([test_case(), test_case()], [ExactMatch, RaisingJudge])
      end
    end

    test "raises the first erroring metric's error, in metrics order" do
      assert_raise MetricError, "{:api_error, 500}", fn ->
        Evaluator.evaluate_single(test_case(), [ExactMatch, FailingMetric, RaisingJudge])
      end
    end

    test "raises for a metric that timed out" do
      assert_raise MetricError, "Metric timed out", fn ->
        Evaluator.evaluate_single(test_case(), [SlowJudge], adapter: :mock, metric_timeout: 50)
      end
    end

    @tag :tmp_dir
    test "raises from DeepEvalEx.evaluate_run/3 without writing a test run",
         %{tmp_dir: tmp_dir} do
      assert_raise MetricError, fn ->
        DeepEvalEx.evaluate_run([test_case()], [ExactMatch, FailingMetric],
          results_folder: tmp_dir
        )
      end

      assert File.ls!(tmp_dir) == []
    end
  end

  describe "ignore_errors: true" do
    test "stores the error on the result and fails it, as deepeval overrides success" do
      assert %Result{score: nil, success: false, error: "{:api_error, 500}", threshold: 0.7} =
               Evaluator.evaluate_metric(test_case(), FailingMetric, ignore_errors: true)
    end

    test "reports missing params as an error unless skip_on_missing_params is set" do
      incomplete = %TestCase{input: "Q", actual_output: nil, expected_output: "A"}

      assert %Result{success: false, skipped: false, error: "'actual_output' cannot be None" <> _} =
               Evaluator.evaluate_metric(incomplete, ExactMatch, ignore_errors: true)
    end
  end

  describe "skip_on_missing_params: true" do
    test "skips a metric whose test case lacks its params, whatever ignore_errors" do
      incomplete = %TestCase{input: "Q", actual_output: "", expected_output: "A"}

      for ignore_errors <- [false, true] do
        assert %Result{metric: "Exact Match", skipped: true, score: nil, success: nil, error: nil} =
                 Evaluator.evaluate_metric(incomplete, ExactMatch,
                   skip_on_missing_params: true,
                   ignore_errors: ignore_errors
                 )
      end
    end

    test "still raises other errors" do
      assert_raise MetricError, fn ->
        Evaluator.evaluate_metric(test_case(), FailingMetric, skip_on_missing_params: true)
      end
    end

    test "leaves the skipped metric out of the test run's metricsData and metricsScores" do
      no_expected = TestCase.new!(input: "Q", actual_output: "A")

      {[[skipped, measured]], test_run, nil} =
        DeepEvalEx.evaluate_run([no_expected], [ExactMatch, %ScoredMetric{}],
          skip_on_missing_params: true
        )

      assert %Result{skipped: true} = skipped
      assert %Result{metric: "Scored", score: 1.0} = measured
      assert [%{metrics_data: [%{name: "Scored"}]}] = test_run.test_cases
      assert [%{metric: "Scored"}] = test_run.metrics_scores
    end
  end

  describe "AsyncConfig options (deepeval's max_concurrent, throttle_value, run_async)" do
    defp probe(opts \\ []) do
      struct!(%ProbeMetric{pid: self(), running: :atomics.new(1, [])}, opts)
    end

    defp test_cases(count) do
      for i <- 1..count, do: %{test_case() | name: "case #{i}"}
    end

    # The highest number of probes seen running at once, and the probes' start
    # times in the order they started.
    defp probe_report do
      probes = receive_probes([])
      {probes |> Enum.map(&elem(&1, 1)) |> Enum.max(), probes |> Enum.map(&elem(&1, 2))}
    end

    defp receive_probes(acc) do
      receive do
        {:probe, label, level, at} -> receive_probes([{label, level, at} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "max_concurrent defaults to 20 test cases at once, as deepeval's" do
      Evaluator.evaluate(test_cases(25), [probe()])

      assert {20, _starts} = probe_report()
    end

    test ":max_concurrent bounds how many test cases are evaluated at once" do
      Evaluator.evaluate(test_cases(5), [probe()], max_concurrent: 2)

      assert {2, _starts} = probe_report()
    end

    test ":concurrency is kept as an alias for :max_concurrent" do
      Evaluator.evaluate(test_cases(5), [probe()], concurrency: 2)

      assert {2, _starts} = probe_report()
    end

    test "metrics of a test case still all run at once by default" do
      running = :atomics.new(1, [])
      metrics = for _ <- 1..3, do: probe(running: running)

      Evaluator.evaluate([test_case()], metrics, max_concurrent: 1)

      assert {3, _starts} = probe_report()
    end

    test "max_concurrent below 1 raises deepeval's error" do
      assert_raise ArgumentError, "'max_concurrent' must be at least 1", fn ->
        Evaluator.evaluate([test_case()], [ExactMatch], max_concurrent: 0)
      end

      assert_raise ArgumentError, "'concurrency' must be at least 1", fn ->
        Evaluator.evaluate([test_case()], [ExactMatch], concurrency: 0)
      end
    end

    test "throttle_value below 0 raises deepeval's error" do
      assert_raise ArgumentError, "'throttle_value' must be at least 0", fn ->
        Evaluator.evaluate([test_case()], [ExactMatch], throttle_value: -0.1)
      end
    end

    test ":throttle_value waits that many seconds between test case launches" do
      Evaluator.evaluate(test_cases(3), [probe(sleep: 0)], throttle_value: 0.1)

      {_peak, [first, second, third]} = probe_report()
      assert second - first >= 100
      assert third - second >= 100
    end

    test "run_async: false evaluates test cases and their metrics one at a time" do
      running = :atomics.new(1, [])
      metrics = [probe(running: running), probe(running: running)]

      Evaluator.evaluate(test_cases(3), metrics,
        run_async: false,
        max_concurrent: 10,
        metric_concurrency: 10
      )

      assert {1, starts} = probe_report()
      assert length(starts) == 6
    end

    test "run_async: false runs evaluate_single's metrics one at a time" do
      running = :atomics.new(1, [])
      metrics = [probe(running: running, label: "a"), probe(running: running, label: "b")]

      assert [_a, _b] = Evaluator.evaluate_single(test_case(), metrics, run_async: false)
      assert {1, _starts} = probe_report()
    end

    test "DeepEvalEx.evaluate/3 honours the AsyncConfig options" do
      {:ok, _evaluation} = DeepEvalEx.evaluate(test_cases(4), [probe()], max_concurrent: 2)

      assert {2, _starts} = probe_report()
    end
  end
end
