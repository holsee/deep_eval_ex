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
  - `:threshold` - Default threshold for all metrics
  - `:model` - Default LLM model for LLM-based metrics
  - `:adapter` - Default LLM adapter

  Run-level options are defaults only: when a metric is passed as a struct,
  any non-nil field on that struct overrides the run-level option of the
  same name, so `GEval.new(threshold: 0.9)` keeps its 0.9 threshold even
  when the run sets `threshold: 0.5`.

  ## Timeouts

  A test case's metrics run concurrently, each in its own process, and the
  results keep the order of the `metrics` list. The per-test-case timeout is
  always kept longer than the time its metrics may legitimately take
  (`:metric_timeout` for each round of `:metric_concurrency` metrics, plus a
  short grace period), so a slow metric errors on its own instead of taking
  down the whole test case. If the test case still exceeds its timeout (for
  example with `metric_timeout: :infinity`), every metric of that test case
  is reported as errored with `"Evaluation timed out"`.

  ## Results

  Returns a list of result lists, one per test case:

      [
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}],
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}]
      ]
  """

  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.{Result, TestCase}

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

  List of result lists, one per test case.
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
          results = evaluate_single(test_case, metrics, opts)
          {results, seconds_since(started)}
        end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, timed_results} ->
          timed_results

        {:exit, :timeout} ->
          {error_results("Evaluation timed out", metrics, opts), timeout / 1000}

        {:exit, reason} ->
          {error_results("Evaluation failed: #{inspect(reason)}", metrics, opts), 0.0}
      end)
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
  longer than `:metric_timeout` (default: `:timeout`) is killed and yields
  an errored `DeepEvalEx.Result` without affecting the other metrics.
  """
  @spec evaluate_single(TestCase.t(), [module() | struct()], keyword()) :: [Result.t()]
  def evaluate_single(test_case, metrics, opts \\ []) do
    results =
      Task.async_stream(
        metrics,
        &evaluate_metric(test_case, &1, opts),
        ordered: true,
        max_concurrency: metric_concurrency(metrics, opts),
        timeout: metric_timeout(opts),
        on_timeout: :kill_task
      )

    metrics
    |> Enum.zip(results)
    |> Enum.map(fn
      {_metric, {:ok, result}} -> result
      {metric, {:exit, :timeout}} -> error_result("Metric timed out", metric, opts)
      {metric, {:exit, reason}} -> error_result("Metric failed: #{inspect(reason)}", metric, opts)
    end)
  end

  @doc """
  Evaluates a single test case against a single metric.

  When the metric returns `{:error, reason}` the result is an errored
  `DeepEvalEx.Result` (see `DeepEvalEx.Result.error/3`) carrying the
  metric's resolved threshold rather than a zero score. As in deepeval, it
  also carries the judge model and the tokens and cost of any LLM calls made
  before the error.

  An exception raised by the metric is reported the same way, with the
  exception's message (`Exception.message/1`) as the error, as deepeval's
  evaluation records `str(exception)`. It does not affect the other metrics.
  """
  @spec evaluate_metric(TestCase.t(), module() | struct(), keyword()) :: Result.t()
  def evaluate_metric(test_case, metric, opts) do
    # Run-level options are defaults; a metric's own configuration wins.
    merged_opts = metric_opts(metric, opts)
    module = metric_module(metric)

    {outcome, usages} =
      BaseMetric.track_usage(fn -> module.measure(test_case, merged_opts) end)

    case outcome do
      {:ok, result} -> result
      {:error, reason} -> error_result(reason, metric, opts, usages)
      {:raised, exception, _stacktrace} -> error_result(exception, metric, opts, usages)
    end
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
  # metric's own defaults in `Keyword.get/3`.
  defp struct_to_opts(struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp error_results(reason, metrics, opts) do
    Enum.map(metrics, &error_result(reason, &1, opts))
  end

  # Errored results carry the metric's judge model even when the metric was
  # killed or made no call, and the usage of the calls it made before erroring.
  defp error_result(reason, metric, opts, usages \\ []) do
    module = metric_module(metric)
    merged_opts = metric_opts(metric, opts)
    usage_fields = BaseMetric.usage_fields(module, merged_opts, usages)

    Result.error(
      metric_name(metric),
      reason,
      [threshold: resolve_threshold(module, merged_opts)] ++ Map.to_list(usage_fields)
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

  # The threshold the metric would have used: its own configuration, then
  # the run-level option, then the metric's default (when it exposes one).
  defp resolve_threshold(module, opts) do
    Keyword.get_lazy(opts, :threshold, fn ->
      if Code.ensure_loaded?(module) and function_exported?(module, :default_threshold, 0) do
        module.default_threshold()
      end
    end)
  end
end
