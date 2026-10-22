defmodule DeepEvalEx.Evaluator do
  @moduledoc """
  Concurrent evaluation engine for DeepEvalEx.

  Evaluates test cases against metrics using BEAM's lightweight
  processes for parallel execution.

  ## Usage

      # Single test case
      [results] = DeepEvalEx.Evaluator.evaluate([test_case], [metric])

      # Multiple test cases (concurrent)
      all_results = DeepEvalEx.Evaluator.evaluate(test_cases, metrics,
        concurrency: 20
      )

  ## Options

  - `:concurrency` - Maximum test cases evaluated at once (default: schedulers * 2)
  - `:metric_concurrency` - Maximum metrics run at once within a single test
    case (default: the number of metrics, i.e. all of them)
  - `:timeout` - Timeout in milliseconds (default: 60_000). Bounds each
    metric unless `:metric_timeout` is given, and bounds each test case
  - `:metric_timeout` - Timeout per metric in milliseconds (default: the
    `:timeout` value). A metric that exceeds it is killed and reported as an
    errored result (`"Metric timed out"`) while its siblings keep running
  - `:threshold` - Default threshold for all metrics; `nil` makes them
    score-only
  - `:strict_mode` - Default strict mode for all metrics (threshold forced
    to `1`, see `DeepEvalEx.Metrics.BaseMetric`)
  - `:flaky` - Default flakiness for all metrics
  - `:model` - Default LLM model for LLM-based metrics
  - `:adapter` - Default LLM adapter
  - `:ignore_errors` - Record a metric's error on its result instead of
    raising it (default: `false`), see "Errors"
  - `:skip_on_missing_params` - Skip a metric whose test case lacks its
    required params instead of erroring (default: `false`), see "Errors"

  Run-level options are defaults only: when a metric is passed as a struct,
  any non-nil field on that struct overrides the run-level option of the
  same name, so `GEval.new(threshold: 0.9)` keeps its 0.9 threshold even
  when the run sets `threshold: 0.5`. A struct's `:threshold` is its
  configuration even when `nil`: like deepeval's `threshold=None`, it makes
  that metric score-only whatever the run sets.

  ## Timeouts

  A test case's metrics run concurrently, each in its own process, and the
  results keep the order of the `metrics` list. The per-test-case timeout is
  always kept longer than the time its metrics may legitimately take
  (`:metric_timeout` for each round of `:metric_concurrency` metrics, plus a
  short grace period), so a slow metric errors on its own instead of taking
  down the whole test case. If the test case still exceeds its timeout (for
  example with `metric_timeout: :infinity`), every metric of that test case
  errors with `"Evaluation timed out"`. Timed-out metrics error like any
  other (see "Errors").

  ## Errors

  These are deepeval's `ErrorConfig(ignore_errors=..., skip_on_missing_params=...)`,
  with its defaults: like deepeval's `evaluate()`, they are not read from the
  `IGNORE_DEEPEVAL_ERRORS` and `SKIP_DEEPEVAL_MISSING_PARAMS` settings,
  which only `DeepEvalEx.ExUnit`'s assertions read, as deepeval's
  `assert_test` does.

  A metric *errors* when it raises, returns `{:error, reason}`, times out or
  crashes. With `ignore_errors: false` the evaluation raises, as deepeval
  re-raises the metric's exception: an exception the metric raised is
  re-raised as it is, any other error raises `DeepEvalEx.MetricError`, or
  `DeepEvalEx.MissingTestCaseParamsError` for missing test case params. The
  first erroring metric, in `test_cases` then `metrics` order, raises;
  metrics still running are stopped and no results are returned.

  With `ignore_errors: true` the error is recorded on the metric's result
  as an errored `DeepEvalEx.Result` (see `DeepEvalEx.Result.error/3`), with
  the error message (`str(exception)`, as deepeval's asynchronous executor
  records it) and `success: false` (`nil` for a score-only metric), and the
  other metrics are unaffected.

  With `skip_on_missing_params: true` a metric whose test case lacks its
  required params is skipped whatever `:ignore_errors` is: its result is
  `DeepEvalEx.Result.skipped/2`, which `DeepEvalEx.TestRun` leaves out of
  `metricsData` and `metricsScores`, and a test case left with no measured
  metric is left out of the test run.

  ## Results

  Returns a list of result lists, one per test case:

      [
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}],
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}]
      ]
  """

  alias DeepEvalEx.{MetricError, MissingTestCaseParamsError, Result, TestCase}
  alias DeepEvalEx.Metrics.BaseMetric

  @default_concurrency System.schedulers_online() * 2
  @default_timeout 60_000

  # Headroom the per-test-case timeout keeps over its metrics' own timeouts,
  # so that a metric timeout is always reported before the test case's.
  @timeout_grace 1_000

  @doc """
  Evaluates test cases against metrics concurrently.

  ## Parameters

  - `test_cases` - List of test cases to evaluate
  - `metrics` - List of metric modules or structs
  - `opts` - Evaluation options

  ## Returns

  List of result lists, one per test case. Raises the first metric error
  unless `:ignore_errors` is set (see "Errors" in the module documentation).
  """
  @spec evaluate([TestCase.t()], [module() | struct()], keyword()) :: [[Result.t()]]
  def evaluate(test_cases, metrics, opts \\ []) do
    {results, _durations} = evaluate_with_durations(test_cases, metrics, opts)
    results
  end

  @doc """
  Evaluates test cases like `evaluate/3`, also returning how long each took.

  Returns `{results, durations}` where `durations` holds the seconds spent
  on each test case, in the same order. A test case that timed out is
  reported as having taken its timeout; one whose process crashed as `0.0`.
  """
  @spec evaluate_with_durations([TestCase.t()], [module() | struct()], keyword()) ::
          {[[Result.t()]], [float()]}
  def evaluate_with_durations(test_cases, metrics, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = case_timeout(metrics, opts)

    :telemetry.execute(
      [:deep_eval_ex, :evaluation, :start],
      %{
        test_case_count: length(test_cases),
        metric_count: length(metrics)
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)

    {results, durations} =
      test_cases
      |> Task.async_stream(
        fn test_case ->
          started = System.monotonic_time()
          outcome = run_single(test_case, metrics, opts)
          {outcome, seconds_since(started)}
        end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while([], fn
        {:ok, {outcome, seconds}}, acc ->
          collect(timed(outcome, seconds), acc)

        {:exit, :timeout}, acc ->
          "Evaluation timed out"
          |> error_outcomes(metrics, opts)
          |> timed(timeout / 1000)
          |> collect(acc)

        {:exit, reason}, acc ->
          "Evaluation failed: #{inspect(reason)}"
          |> error_outcomes(metrics, opts)
          |> timed(0.0)
          |> collect(acc)
      end)
      |> unwrap!()
      |> Enum.unzip()

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:deep_eval_ex, :evaluation, :stop],
      %{duration: duration, test_case_count: length(test_cases)},
      %{}
    )

    {results, durations}
  end

  @doc """
  Evaluates a single test case against all metrics.

  Metrics run concurrently (bounded by `:metric_concurrency`) and the
  results are returned in the same order as `metrics`. A metric that runs
  longer than `:metric_timeout` (default: `:timeout`) is killed and errors
  with `"Metric timed out"` without affecting the other metrics: with
  `ignore_errors: true` it yields an errored `DeepEvalEx.Result`, otherwise
  it raises (see "Errors" in the module documentation).
  """
  @spec evaluate_single(TestCase.t(), [module() | struct()], keyword()) :: [Result.t()]
  def evaluate_single(test_case, metrics, opts \\ []) do
    test_case |> run_single(metrics, opts) |> unwrap!()
  end

  # {:ok, results}, or the first metric error to raise in metrics order;
  # halting the stream stops the metrics still running.
  defp run_single(test_case, metrics, opts) do
    outcomes =
      Task.async_stream(
        metrics,
        &measure_metric(test_case, &1, opts),
        ordered: true,
        max_concurrency: metric_concurrency(metrics, opts),
        timeout: metric_timeout(opts),
        on_timeout: :kill_task
      )

    metrics
    |> Stream.zip(outcomes)
    |> Enum.reduce_while([], fn
      {_metric, {:ok, outcome}}, acc ->
        collect(outcome, acc)

      {metric, {:exit, :timeout}}, acc ->
        collect(error_outcome("Metric timed out", metric, opts), acc)

      {metric, {:exit, reason}}, acc ->
        collect(error_outcome("Metric failed: #{inspect(reason)}", metric, opts), acc)
    end)
    |> collected()
  end

  @doc """
  Evaluates a single test case against a single metric.

  When the metric returns `{:error, reason}` the result is an errored
  `DeepEvalEx.Result` (see `DeepEvalEx.Result.error/3`) carrying the
  metric's resolved threshold rather than a zero score. As in deepeval, it
  also carries the judge model and the tokens and cost of any LLM calls made
  before the error.

  The metric gets deepeval's strict mode, score-only and flaky semantics
  even when it implements `DeepEvalEx.Metrics.BaseMetric` without `use`
  (see that module).

  An exception raised by the metric is reported the same way, with the
  exception's message (`Exception.message/1`) as the error, as deepeval's
  evaluation records `str(exception)`. It does not affect the other metrics.

  That is with `ignore_errors: true`. By default the error is raised, and
  `skip_on_missing_params: true` skips a metric missing test case params
  instead (see "Errors" in the module documentation).
  """
  @spec evaluate_metric(TestCase.t(), module() | struct(), keyword()) :: Result.t()
  def evaluate_metric(test_case, metric, opts) do
    test_case |> measure_metric(metric, opts) |> unwrap!()
  end

  defp measure_metric(test_case, metric, opts) do
    # Run-level options are defaults; a metric's own configuration wins.
    module = metric_module(metric)
    merged_opts = BaseMetric.strict_opts(metric_opts(metric, opts), default_threshold(module))

    {outcome, usages} =
      BaseMetric.track_usage(fn -> module.measure(test_case, merged_opts) end)

    case outcome do
      # Also covers metrics that implement the behaviour without `use`.
      {:ok, result} ->
        {:ok, BaseMetric.apply_metric_semantics(result, merged_opts)}

      {:error, reason} ->
        error_outcome(reason, metric, opts, usages)

      {:raised, exception, stacktrace} ->
        error_outcome(exception, metric, opts, usages, stacktrace)
    end
  end

  # deepeval's _execute_metric and safe_a_measure: a metric missing params
  # is skipped with skip_on_missing_params; otherwise its error is stored
  # with ignore_errors, else raised. `{:raise, exception, stacktrace}`
  # re-raises an exception the metric raised; a nil stacktrace raises anew.
  defp error_outcome(reason, metric, opts, usages \\ [], stacktrace \\ nil) do
    cond do
      missing_params?(reason) and Keyword.get(opts, :skip_on_missing_params, false) ->
        {:ok, skipped_result(metric, opts)}

      Keyword.get(opts, :ignore_errors, false) ->
        {:ok, error_result(reason, metric, opts, usages)}

      stacktrace != nil ->
        {:raise, reason, stacktrace}

      true ->
        {:raise, metric_error(reason, metric, opts, usages), nil}
    end
  end

  # Every metric of a killed test case errors with `reason`.
  defp error_outcomes(reason, metrics, opts) do
    metrics
    |> Enum.reduce_while([], &collect(error_outcome(reason, &1, opts), &2))
    |> collected()
  end

  # An Enum.reduce_while/3 step: accumulates results, in reverse, until an
  # outcome raises; collected/1 then gives {:ok, results} or that outcome.
  defp collect({:ok, result}, acc), do: {:cont, [result | acc]}
  defp collect(raise, _acc), do: {:halt, raise}

  defp collected(results) when is_list(results), do: {:ok, Enum.reverse(results)}
  defp collected(raise), do: raise

  defp timed({:ok, results}, seconds), do: {:ok, {results, seconds}}
  defp timed(raise, _seconds), do: raise

  defp unwrap!(results) when is_list(results), do: unwrap!(collected(results))
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:raise, exception, nil}), do: raise(exception)
  defp unwrap!({:raise, exception, stacktrace}), do: reraise(exception, stacktrace)

  defp missing_params?({:missing_params, params}) when is_list(params), do: true
  defp missing_params?({:empty_param, param}) when is_atom(param), do: true
  defp missing_params?(%MissingTestCaseParamsError{}), do: true
  defp missing_params?(_reason), do: false

  # Raised with the metric's state when it errored, as deepeval's metric is
  # left after measure() raises: only ignore_errors sets success to false.
  defp metric_error(reason, metric, opts, usages) do
    result = %{error_result(reason, metric, opts, usages) | success: nil}
    module = if missing_params?(reason), do: MissingTestCaseParamsError, else: MetricError
    struct!(module, message: result.error, metric: result.metric, reason: reason, result: result)
  end

  defp skipped_result(metric, opts) do
    module = metric_module(metric)
    merged_opts = metric_opts(metric, opts)

    Result.skipped(
      metric_name(metric),
      threshold_opts(module, merged_opts) ++
        [
          strict_mode: Keyword.get(merged_opts, :strict_mode, false),
          flaky: Keyword.get(merged_opts, :flaky, false)
        ]
    )
  end

  @doc """
  Raises unless at least one metric has a threshold and is not flaky, as
  deepeval's `check_at_least_one_metric_has_threshold` does before
  `evaluate()` and `assert_test()` run: otherwise no test case could ever
  pass or fail.

  A metric's threshold and flakiness are resolved from `opts` and its own
  configuration as for evaluation (strict mode counts as a threshold of
  `1`). A metric module that defines no `default_threshold/0` is assumed to
  have a threshold unless `:threshold` is `nil`.

  Raises `ArgumentError` with deepeval's `ValueError` message.
  """
  @spec check_at_least_one_metric_has_threshold!([module() | struct()], keyword()) :: :ok
  def check_at_least_one_metric_has_threshold!(metrics, opts) do
    if Enum.any?(metrics, &decides_success?(&1, opts)) do
      :ok
    else
      raise ArgumentError,
            "You must provide at least one non-flaky metric with a 'threshold', " <>
              "otherwise test cases can never pass or fail."
    end
  end

  defp decides_success?(metric, opts) do
    merged_opts = metric_opts(metric, opts)
    module = metric_module(metric)

    has_threshold? =
      case threshold_opts(module, merged_opts) do
        [threshold: threshold] -> not is_nil(threshold)
        [] -> true
      end

    has_threshold? and not Keyword.get(merged_opts, :flaky, false)
  end

  defp seconds_since(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000_000
  end

  defp metric_concurrency(metrics, opts) do
    Keyword.get_lazy(opts, :metric_concurrency, fn -> max(length(metrics), 1) end)
  end

  defp metric_timeout(opts) do
    Keyword.get_lazy(opts, :metric_timeout, fn ->
      Keyword.get(opts, :timeout, @default_timeout)
    end)
  end

  # The per-test-case timeout: `:timeout`, raised when needed so it outlasts
  # every round of `:metric_concurrency` metrics running to their own
  # `:metric_timeout`. Metric timeouts therefore fire first and error only
  # the slow metric. With no metric bound only `:timeout` applies.
  defp case_timeout(metrics, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case metric_timeout(opts) do
      :infinity ->
        timeout

      _metric_timeout when timeout == :infinity ->
        :infinity

      metric_timeout ->
        rounds = ceil(length(metrics) / metric_concurrency(metrics, opts))
        max(timeout, rounds * metric_timeout + @timeout_grace)
    end
  end

  defp metric_module(metric) when is_atom(metric), do: metric
  defp metric_module(%{__struct__: module}), do: module

  defp metric_opts(metric, opts) when is_atom(metric), do: opts
  defp metric_opts(metric, opts), do: Keyword.merge(opts, struct_to_opts(metric))

  # Convert a metric struct to an options keyword list, dropping unset
  # (nil) fields so they neither mask run-level options nor shadow the
  # metric's own defaults in `Keyword.get/3`. A nil `:threshold` is kept: it
  # is the metric's score-only configuration, as deepeval's `threshold=None`.
  defp struct_to_opts(struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)
  end

  # Errored results carry the metric's judge model even when the metric was
  # killed or made no call, and the usage of the calls it made before erroring.
  defp error_result(reason, metric, opts, usages) do
    module = metric_module(metric)
    merged_opts = metric_opts(metric, opts)
    usage_fields = BaseMetric.usage_fields(module, merged_opts, usages)

    Result.error(
      metric_name(metric),
      reason,
      threshold_opts(module, merged_opts) ++
        [
          strict_mode: Keyword.get(merged_opts, :strict_mode, false),
          flaky: Keyword.get(merged_opts, :flaky, false)
        ] ++ Map.to_list(usage_fields)
    )
  end

  # A configured struct may name its results after its configuration (e.g.
  # GEval's "<name> [GEval]"); otherwise fall back to the module's name.
  defp metric_name(%{__struct__: module} = metric) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metric_name, 1) do
      module.metric_name(metric)
    else
      module.metric_name()
    end
  end

  defp metric_name(module) when is_atom(module), do: module.metric_name()

  # `[threshold: threshold]` with the threshold the metric would have used:
  # 1 in strict mode, else its own configuration, then the run-level option,
  # then the metric's default. `[]` when it is unknown: no option is given
  # and the metric exposes no default.
  defp threshold_opts(module, opts) do
    if Keyword.has_key?(opts, :threshold) or Keyword.get(opts, :strict_mode, false) or
         exports_default_threshold?(module),
       do: [threshold: BaseMetric.threshold(opts, default_threshold(module))],
       else: []
  end

  defp default_threshold(module) do
    if exports_default_threshold?(module), do: module.default_threshold()
  end

  defp exports_default_threshold?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :default_threshold, 0)
  end
end
