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
        max_concurrent: 10
      )

  ## Options

  - `:max_concurrent` - Maximum test cases evaluated at once (default: `20`,
    at least `1`); `:concurrency` is an alias, see "Concurrency"
  - `:throttle_value` - Seconds to wait between launching test cases
    (default: `0`, at least `0`), see "Concurrency"
  - `:run_async` - Evaluate concurrently (default: `true`); `false`
    evaluates test cases and their metrics one at a time, see "Concurrency"
  - `:metric_concurrency` - Maximum metrics run at once within a single test
    case (default: the number of metrics, i.e. all of them)
  - `:timeout` - Timeout in milliseconds (default: deepeval's per-task
    timeout, `DeepEvalEx.Config.per_task_timeout_seconds/0`: the
    `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` setting, else 180 seconds).
    Bounds each metric unless `:metric_timeout` is given, and bounds each
    test case, see "Timeouts"
  - `:metric_timeout` - Timeout per metric in milliseconds (default: the
    `:timeout` value). A metric that exceeds it is killed and reported as an
    errored result while its siblings keep running, see "Timeouts"
  - `:threshold` - Default threshold for all metrics; `nil` makes them
    score-only
  - `:strict_mode` - Default strict mode for all metrics (threshold forced
    to `1`, see `DeepEvalEx.Metrics.BaseMetric`)
  - `:flaky` - Default flakiness for all metrics
  - `:model` - Default LLM model for LLM-based metrics
  - `:adapter` - Default LLM adapter
  - `:eval_mode` - Default eval mode for all metrics (`:llm`, `:hybrid` or
    `:system_one`), see "System One"
  - `:system_one_model` - Default System One model, see "System One"
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

  ## System One

  Before any test case starts, every metric's
  `DeepEvalEx.SystemOne.Context` is resolved from its options
  (`DeepEvalEx.SystemOne.Context.resolve!/2`), once for the whole run, as
  deepeval builds a metric's models when the metric is created. An
  unrecognised `:eval_mode` or `:system_one_model` raises `ArgumentError`,
  and a System One model whose `init/1` fails raises
  `DeepEvalEx.DeepEvalError`, whatever `:ignore_errors` says. Each metric
  then gets its context as `opts[:system_one]`.

  When two or more of a test case's metrics run under `:system_one`, their
  System One requests are merged, as deepeval's `evaluate()` batches them
  (`DeepEvalEx.SystemOne.Batch`): before the test case's metrics start, as
  few requests as the context budget allows ask every question, bounded by
  the test case's timeout, and each request's cost and tokens are split
  among its metrics by their share of its questions. Each metric then
  measures as usual with its own answers. A failed request fails each of
  its metrics without falling back to the LLM: with `ignore_errors: true`
  the error recorded is deepeval's `"<type>: <message>"` text
  (`"ConnectionError: Jev is down"`), otherwise the request's error is
  raised. A metric whose test case lacks its params errors the same way
  (`"MissingTestCaseParamsError: ..."`), or is skipped with
  `skip_on_missing_params: true`.

  ## Concurrency

  `:max_concurrent`, `:throttle_value` and `:run_async` are deepeval's
  `AsyncConfig(max_concurrent=..., throttle_value=..., run_async=...)`, with
  its defaults and its validation: a `:max_concurrent` below `1` raises
  `ArgumentError` with `"'max_concurrent' must be at least 1"`, a
  `:throttle_value` below `0` with `"'throttle_value' must be at least 0"`.

  As in deepeval, `:max_concurrent` bounds the test cases being evaluated,
  while each test case's metrics all run at once unless `:metric_concurrency`
  bounds them. `:concurrency` is the older name of `:max_concurrent` and is
  still accepted (`"'concurrency' must be at least 1"`); `:max_concurrent`
  wins when both are given.

  With `:throttle_value` the evaluation waits that many seconds after
  launching a test case before launching the next, as deepeval sleeps
  between creating its tasks; the wait is not counted in the test case's
  duration or timeout.

  `run_async: false` is deepeval's synchronous executor: test cases and their
  metrics are evaluated one at a time, whatever `:max_concurrent` and
  `:metric_concurrency` say, and `:throttle_value` is not applied (deepeval's
  synchronous executor does not throttle). Each metric still runs in its own
  process, so `:metric_timeout` applies, and `:timeout` bounds the whole
  test case (see "Timeouts"). An error recorded with
  `ignore_errors: true` still keeps the message alone, as deepeval's
  asynchronous executor records it, not the synchronous executor's
  `DeepEvalEx.Result.format_error_text/2`.

  ## Timeouts

  `:timeout` defaults to deepeval's per-task timeout, so
  `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` (or
  `config :deep_eval_ex, per_task_timeout_seconds_override:`) sets it as it
  sets deepeval's; without it, it is deepeval's 180 seconds.

  A test case's metrics run concurrently, each in its own process, and the
  results keep the order of the `metrics` list. The per-test-case timeout is
  always kept longer than the time its metrics may legitimately take
  (`:metric_timeout` for each round of `:metric_concurrency` metrics, plus a
  short grace period), so a slow metric errors on its own instead of taking
  down the whole test case. If the test case still exceeds its timeout (for
  example with `metric_timeout: :infinity`), the metrics that finished keep
  their results and the others error. Either way a timed-out metric errors
  with deepeval's asynchronous executor's message:

      Timed out/cancelled while evaluating metric. Increase
      DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set
      DEEPEVAL_LOG_STACK_TRACES=1 for full traceback.

  (on one line). With `run_async: false`, as deepeval's synchronous
  executor, `:timeout` bounds the whole test case: the metric running when
  it elapses errors with `"Timed out after <seconds>s while evaluating
  metric. Increase DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set
  DEEPEVAL_LOG_STACK_TRACES=1 for full traceback."`, the seconds being the
  timeout to two decimals (`"0.10"`), and every metric after it with
  `"Skipped due to case timeout."`. A metric exceeding a shorter
  `:metric_timeout` gets the same message with that timeout's seconds,
  and the metrics after it still run.

  Timed-out and skipped metrics error like any other (see "Errors"): with
  `ignore_errors: true` they are errored results with `success: false`
  (`nil` for a score-only metric), as deepeval's `is_successful()` reports
  them, otherwise the first of them raises a `DeepEvalEx.MetricError` with
  the message.

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

  alias DeepEvalEx.{Config, MetricError, MissingTestCaseParamsError, Result, TestCase}
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.{Batch, Context}

  # Where the run keeps each metric's resolved System One context.
  @contexts_key :__system_one_contexts__

  # deepeval's AsyncConfig defaults.
  @default_max_concurrent 20
  @default_throttle_value 0

  # deepeval 4.3.1's errors for a metric its per-task timeout stopped: the
  # asynchronous executor's for a cancelled metric (safe_a_measure), and the
  # synchronous executor's for metrics left after the one that timed out
  # (execute_test_cases; that one gets timed_out_message/1).
  @cancelled_message "Timed out/cancelled while evaluating metric. " <>
                       "Increase DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set " <>
                       "DEEPEVAL_LOG_STACK_TRACES=1 for full traceback."
  @skipped_message "Skipped due to case timeout."

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
  reported as having run until its deadline; one whose process crashed as
  `0.0`.
  """
  @spec evaluate_with_durations([TestCase.t()], [module() | struct()], keyword()) ::
          {[[Result.t()]], [float()]}
  def evaluate_with_durations(test_cases, metrics, opts \\ []) do
    {opts, throttle_value} = async_config!(opts)
    opts = preflight(metrics, opts)
    concurrency = Keyword.fetch!(opts, :concurrency)
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
      |> throttled(throttle_value)
      |> Task.async_stream(
        fn test_case ->
          started = System.monotonic_time()
          outcome = run_single(test_case, metrics, opts)
          {outcome, seconds_since(started)}
        end,
        max_concurrency: concurrency,
        timeout: with_grace(timeout),
        on_timeout: :kill_task
      )
      |> Enum.reduce_while([], fn
        {:ok, {outcome, seconds}}, acc ->
          collect(timed(outcome, seconds), acc)

        {:exit, :timeout}, acc ->
          @cancelled_message
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
  with deepeval's timeout message without affecting the other metrics: with
  `ignore_errors: true` it yields an errored `DeepEvalEx.Result`, otherwise
  it raises (see "Timeouts" and "Errors" in the module documentation).
  """
  @spec evaluate_single(TestCase.t(), [module() | struct()], keyword()) :: [Result.t()]
  def evaluate_single(test_case, metrics, opts \\ []) do
    {opts, _throttle_value} = async_config!(opts)
    test_case |> run_single(metrics, preflight(metrics, opts)) |> unwrap!()
  end

  # {:ok, results}, or the first metric error to raise in metrics order;
  # halting the stream stops the metrics still running. The test case's
  # deadline starts now: each metric runs until its own :metric_timeout or
  # the deadline, whichever comes first.
  defp run_single(test_case, metrics, opts) do
    deadline = deadline(case_timeout(metrics, opts))
    prefetched = prefetch(test_case, metrics, deadline, opts)

    outcomes =
      Task.async_stream(
        Enum.zip(metrics, prefetched),
        fn {metric, prefetched} ->
          measure_until(test_case, metric, prefetched, deadline, opts)
        end,
        ordered: true,
        max_concurrency: metric_concurrency(metrics, opts),
        timeout: :infinity
      )

    metrics
    |> Stream.zip(outcomes)
    |> Enum.reduce_while([], fn
      {_metric, {:ok, outcome}}, acc ->
        collect(outcome, acc)

      {metric, {:exit, reason}}, acc ->
        collect(error_outcome("Metric failed: #{inspect(reason)}", metric, opts), acc)
    end)
    |> collected()
  end

  # The test case's :system_one metrics' System One answers, asked in as
  # few requests as possible before any metric starts (see "System One"),
  # one Batch outcome per metric. The requests run until the deadline.
  defp prefetch(test_case, metrics, deadline, opts) do
    entries = Enum.map(metrics, &{metric_module(&1), measure_opts(&1, opts)})

    Batch.prefetch(test_case, entries,
      timeout: remaining(deadline),
      max_concurrency: if(Keyword.get(opts, :run_async, true), do: length(metrics), else: 1)
    )
  end

  # Measures `metric` in its own process, killed when it outlives its
  # :metric_timeout or the test case's deadline. A metric whose turn comes
  # after the deadline is not started, nor one whose part in the System
  # One batch could not be prepared.
  defp measure_until(_test_case, metric, {:setup_failed, error}, _deadline, opts),
    do: error_outcome(error, metric, opts)

  defp measure_until(test_case, metric, prefetched, deadline, opts) do
    case remaining(deadline) do
      0 -> error_outcome(unstarted_message(opts), metric, opts)
      remaining -> measure_within(test_case, metric, prefetched, remaining, opts)
    end
  end

  defp measure_within(test_case, metric, prefetched, remaining, opts) do
    metric_timeout = metric_timeout(opts)
    task = Task.async(fn -> measure_metric(test_case, metric, prefetched, opts) end)

    case Task.yield(task, min_timeout(metric_timeout, remaining)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        error_outcome("Metric failed: #{inspect(reason)}", metric, opts)

      nil ->
        bound = if shorter?(metric_timeout, remaining), do: metric_timeout, else: :case
        error_outcome(timeout_message(bound, opts), metric, opts)
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp shorter?(:infinity, _other), do: false
  defp shorter?(_timeout, :infinity), do: true
  defp shorter?(timeout, other), do: timeout < other

  defp min_timeout(a, b), do: if(shorter?(a, b), do: a, else: b)

  defp with_grace(:infinity), do: :infinity
  defp with_grace(timeout), do: timeout + @timeout_grace

  # The error of a metric that timed out, `bound` being its :metric_timeout
  # or `:case` for the test case's deadline. deepeval's asynchronous executor
  # cancels it; its synchronous executor names the timeout that elapsed
  # (`_timeout_msg("evaluating metric", seconds)`).
  defp timeout_message(bound, opts) do
    cond do
      Keyword.get(opts, :run_async, true) -> @cancelled_message
      bound == :case -> timed_out_message(timeout(opts))
      true -> timed_out_message(bound)
    end
  end

  # The error of a metric not started before the test case's deadline:
  # cancelled with the others by deepeval's asynchronous executor, skipped
  # by its synchronous executor.
  defp unstarted_message(opts) do
    if Keyword.get(opts, :run_async, true), do: @cancelled_message, else: @skipped_message
  end

  defp timed_out_message(timeout) do
    seconds = Python.format_fixed(timeout / 1000, 2)

    "Timed out after #{seconds}s while evaluating metric. " <>
      "Increase DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set " <>
      "DEEPEVAL_LOG_STACK_TRACES=1 for full traceback."
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
    test_case |> measure_metric(metric, nil, preflight([metric], opts)) |> unwrap!()
  end

  # Resolves every metric's System One context up front (see "System One"),
  # keeping those already resolved.
  defp preflight(metrics, opts) do
    contexts =
      Enum.reduce(metrics, Keyword.get(opts, @contexts_key, %{}), fn metric, contexts ->
        Map.put_new_lazy(contexts, metric, fn ->
          Context.resolve!(metric_module(metric), metric_opts(metric, opts))
        end)
      end)

    Keyword.put(opts, @contexts_key, contexts)
  end

  defp put_context(merged_opts, metric, opts) do
    case Keyword.get(opts, @contexts_key, %{}) do
      %{^metric => context} -> Keyword.put(merged_opts, :system_one, context)
      _contexts -> merged_opts
    end
  end

  # The options `metric` measures with. Run-level options are defaults; a
  # metric's own configuration wins.
  defp measure_opts(metric, opts) do
    metric
    |> metric_opts(opts)
    |> BaseMetric.strict_opts(default_threshold(metric_module(metric)))
    |> put_context(metric, opts)
  end

  # `prefetched` is the metric's System One batch outcome, if any.
  defp measure_metric(test_case, metric, prefetched, opts) do
    module = metric_module(metric)

    merged_opts =
      case prefetched do
        nil -> measure_opts(metric, opts)
        prefetched -> Keyword.put(measure_opts(metric, opts), :system_one_prefetched, prefetched)
      end

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
  #
  # A Batch.Error is the error of the metric's System One batch: ignored, it
  # records deepeval's format_error_text; otherwise its original is raised,
  # or skipped when it is missing params.
  defp error_outcome(reason, metric, opts, usages \\ [], stacktrace \\ nil)

  defp error_outcome(%Batch.Error{original: original} = error, metric, opts, usages, stacktrace) do
    if Keyword.get(opts, :ignore_errors, false) and
         not (missing_params?(original) and Keyword.get(opts, :skip_on_missing_params, false)),
       do: {:ok, error_result(error, metric, opts, usages)},
       else:
         error_outcome(original, metric, opts, usages, original_stacktrace(original, stacktrace))
  end

  defp error_outcome(reason, metric, opts, usages, stacktrace) do
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

  # An exception is re-raised as it is; a missing-params error raises anew.
  defp original_stacktrace(original, stacktrace) when is_exception(original),
    do: stacktrace || []

  defp original_stacktrace(_original, _stacktrace), do: nil

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

  # deepeval's AsyncConfig: validates :max_concurrent (or its :concurrency
  # alias) and :throttle_value, and resolves them onto :concurrency,
  # :metric_concurrency and the throttle in seconds. run_async: false is
  # deepeval's synchronous executor: one test case and one metric at a time,
  # unthrottled.
  defp async_config!(opts) do
    concurrency = max_concurrent!(opts)
    throttle_value = throttle_value!(opts)

    if Keyword.get(opts, :run_async, true) do
      {Keyword.put(opts, :concurrency, concurrency), throttle_value}
    else
      {Keyword.merge(opts, concurrency: 1, metric_concurrency: 1), 0}
    end
  end

  defp max_concurrent!(opts) do
    {name, value} =
      cond do
        Keyword.has_key?(opts, :max_concurrent) -> {:max_concurrent, opts[:max_concurrent]}
        Keyword.has_key?(opts, :concurrency) -> {:concurrency, opts[:concurrency]}
        true -> {:max_concurrent, @default_max_concurrent}
      end

    if is_integer(value) and value >= 1,
      do: value,
      else: raise(ArgumentError, "'#{name}' must be at least 1")
  end

  defp throttle_value!(opts) do
    value = Keyword.get(opts, :throttle_value, @default_throttle_value)

    if is_number(value) and value >= 0,
      do: value,
      else: raise(ArgumentError, "'throttle_value' must be at least 0")
  end

  # Waits `seconds` before yielding each test case but the first, so that
  # Task.async_stream/3 launches them that far apart.
  defp throttled(test_cases, seconds) when seconds == 0, do: test_cases

  defp throttled(test_cases, seconds) do
    wait = round(seconds * 1_000)

    test_cases
    |> Stream.with_index()
    |> Stream.map(fn
      {test_case, 0} ->
        test_case

      {test_case, _index} ->
        Process.sleep(wait)
        test_case
    end)
  end

  defp seconds_since(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000_000
  end

  defp metric_concurrency(metrics, opts) do
    Keyword.get_lazy(opts, :metric_concurrency, fn -> max(length(metrics), 1) end)
  end

  # deepeval's per-task timeout (DEEPEVAL_PER_TASK_TIMEOUT_SECONDS), in
  # milliseconds, unless given.
  defp timeout(opts) do
    Keyword.get_lazy(opts, :timeout, fn -> round(Config.per_task_timeout_seconds() * 1_000) end)
  end

  defp metric_timeout(opts) do
    Keyword.get_lazy(opts, :metric_timeout, fn -> timeout(opts) end)
  end

  # The per-test-case timeout. With run_async: false it is `:timeout`, as
  # deepeval's synchronous executor bounds the whole test case with its
  # per-task timeout. Otherwise it is `:timeout`, raised when needed so it
  # outlasts every round of `:metric_concurrency` metrics running to their
  # own `:metric_timeout`: metric timeouts therefore fire first and error
  # only the slow metric. With no metric bound only `:timeout` applies.
  defp case_timeout(metrics, opts) do
    timeout = timeout(opts)
    metric_timeout = metric_timeout(opts)

    cond do
      not Keyword.get(opts, :run_async, true) ->
        timeout

      metric_timeout == :infinity ->
        timeout

      timeout == :infinity ->
        :infinity

      true ->
        rounds = ceil(length(metrics) / metric_concurrency(metrics, opts))
        max(timeout, rounds * metric_timeout + @timeout_grace)
    end
  end

  defp metric_module(metric) when is_atom(metric), do: metric
  defp metric_module(%{__struct__: module}), do: module

  defp metric_opts(metric, opts) when is_atom(metric), do: Keyword.delete(opts, @contexts_key)

  defp metric_opts(metric, opts),
    do: opts |> Keyword.delete(@contexts_key) |> Keyword.merge(struct_to_opts(metric))

  # Convert a metric struct to an options keyword list, dropping unset
  # (nil) fields so they neither mask run-level options nor shadow the
  # metric's own defaults in `Keyword.get/3`. A nil `:threshold` is kept: it
  # is the metric's score-only configuration, as deepeval's `threshold=None`.
  defp struct_to_opts(struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)
  end

  # Errored results carry the metric's judge model (its System One model
  # under :system_one) even when the metric was killed or made no call, and
  # the usage of the calls it made before erroring.
  defp error_result(reason, metric, opts, usages) do
    module = metric_module(metric)
    merged_opts = metric |> metric_opts(opts) |> put_context(metric, opts)
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
