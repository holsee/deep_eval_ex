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

  - `:concurrency` - Maximum concurrent evaluations (default: schedulers * 2)
  - `:timeout` - Timeout per test case in milliseconds (default: 60_000)
  - `:threshold` - Default threshold for all metrics
  - `:model` - Default LLM model for LLM-based metrics
  - `:adapter` - Default LLM adapter

  ## Results

  Returns a list of result lists, one per test case:

      [
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}],
        [%Result{metric: "Metric1", ...}, %Result{metric: "Metric2", ...}]
      ]
  """

  alias DeepEvalEx.{TestCase, Result}

  @default_concurrency System.schedulers_online() * 2
  @default_timeout 60_000

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
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    :telemetry.execute(
      [:deep_eval_ex, :evaluation, :start],
      %{
        test_case_count: length(test_cases),
        metric_count: length(metrics)
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)

    results =
      test_cases
      |> Task.async_stream(
        fn test_case ->
          evaluate_single(test_case, metrics, opts)
        end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, results} -> results
        {:exit, :timeout} -> [error_result("Evaluation timed out", metrics)]
        {:exit, reason} -> [error_result("Evaluation failed: #{inspect(reason)}", metrics)]
      end)

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:deep_eval_ex, :evaluation, :stop],
      %{duration: duration, test_case_count: length(test_cases)},
      %{}
    )

    results
  end

  @doc """
  Evaluates a single test case against all metrics.
  """
  @spec evaluate_single(TestCase.t(), [module() | struct()], keyword()) :: [Result.t()]
  def evaluate_single(test_case, metrics, opts \\ []) do
    metrics
    |> Enum.map(fn metric ->
      evaluate_metric(test_case, metric, opts)
    end)
  end

  @doc """
  Evaluates a single test case against a single metric.
  """
  @spec evaluate_metric(TestCase.t(), module() | struct(), keyword()) :: Result.t()
  def evaluate_metric(test_case, metric, opts) when is_atom(metric) do
    case metric.measure(test_case, opts) do
      {:ok, result} -> result
      {:error, reason} -> error_result_single(reason, metric.metric_name())
    end
  end

  def evaluate_metric(test_case, %{__struct__: module} = metric_struct, opts) do
    # For metric structs that contain configuration
    merged_opts = Keyword.merge(struct_to_opts(metric_struct), opts)

    case module.measure(test_case, merged_opts) do
      {:ok, result} -> result
      {:error, reason} -> error_result_single(reason, module.metric_name())
    end
  end

  # Convert a metric struct to options keyword list
  defp struct_to_opts(struct) do
    struct
    |> Map.from_struct()
    |> Map.to_list()
    |> Keyword.new()
  end

  defp error_result(reason, metrics) do
    Enum.map(metrics, fn metric ->
      name =
        cond do
          is_atom(metric) -> metric.metric_name()
          is_struct(metric) -> metric.__struct__.metric_name()
          true -> "Unknown"
        end

      error_result_single(reason, name)
    end)
  end

  defp error_result_single(reason, metric_name) do
    %Result{
      metric: metric_name,
      score: 0.0,
      success: false,
      reason: format_error(reason),
      threshold: 0.0
    }
  end

  defp format_error({:missing_params, params}) do
    "Missing required parameters: #{Enum.join(params, ", ")}"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
