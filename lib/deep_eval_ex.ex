# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# This file is part of DeepEvalEx, a derivative work of DeepEval
# (https://github.com/confident-ai/deepeval) by Confident AI.

defmodule DeepEvalEx do
  @moduledoc """
  DeepEvalEx - LLM Evaluation Framework for Elixir

  A pure Elixir port of DeepEval, providing metrics and tooling
  to evaluate Large Language Model outputs.

  This project is a derivative work of [DeepEval](https://github.com/confident-ai/deepeval)
  by Confident AI, licensed under Apache 2.0.

  ## Quick Start

      # Define a test case
      test_case = %DeepEvalEx.TestCase{
        input: "What is the capital of France?",
        actual_output: "The capital of France is Paris.",
        expected_output: "Paris"
      }

      # Create a metric
      metric = DeepEvalEx.Metrics.GEval.new(
        name: "Correctness",
        criteria: "Determine if the actual output is factually correct",
        evaluation_params: [:input, :actual_output]
      )

      # Evaluate
      {:ok, %DeepEvalEx.EvaluationResult{test_results: [test_result]}} =
        DeepEvalEx.evaluate([test_case], [metric])

      test_result.success
      test_result.metrics_data
      #=> [%DeepEvalEx.Result{metric: "Correctness [GEval]", score: 0.9, ...}]

  ## Metrics

  - `DeepEvalEx.Metrics.ExactMatch` - Simple string comparison
  - `DeepEvalEx.Metrics.GEval` - Flexible criteria-based evaluation
  - `DeepEvalEx.Metrics.Faithfulness` - RAG: claims supported by context
  - `DeepEvalEx.Metrics.Hallucination` - Detects unsupported statements
  - `DeepEvalEx.Metrics.AnswerRelevancy` - Response relevance to question
  - `DeepEvalEx.Metrics.ContextualPrecision` - RAG retrieval ranking quality
  - `DeepEvalEx.Metrics.ContextualRecall` - RAG coverage of ground truth
  - `DeepEvalEx.Metrics.ToolCorrectness` - Agent tool calls against the
    expected tools

  ## LLM Providers

  LLM-as-judge metrics call a provider through a `DeepEvalEx.LLM.Adapter`,
  chosen with the `:adapter` option or the `:default_model` config:

  - `DeepEvalEx.LLM.Adapters.OpenAI` (`:openai`) - OpenAI chat completions,
    or any OpenAI-compatible gateway via `:base_url` / `OPENAI_BASE_URL`
  - `DeepEvalEx.LLM.Adapters.Anthropic` (`:anthropic`) - Claude models via
    the Messages API
  - `DeepEvalEx.LLM.Adapters.Ollama` (`:ollama`) - local models via
    Ollama's `/api/chat`
  - `DeepEvalEx.LLM.Adapters.Mock` (`:mock`) - canned responses for tests

  Each records token usage and cost on the results; see
  `DeepEvalEx.LLM.Usage`.

  ## Configuration

      config :deep_eval_ex,
        default_model: {:openai, "gpt-4o-mini"},
        openai_api_key: System.get_env("OPENAI_API_KEY"),
        default_threshold: 0.5

  ## deepeval Test Runs

  `evaluate_run/3` saves runs as deepeval's `test_run_<timestamp>.json` and
  `DeepEvalEx.TestRun.load/1` reads them back; see `DeepEvalEx.TestRun`.
  """

  require Logger

  alias DeepEvalEx.{EvaluationResult, Evaluator, Result, TestCase, TestRun}
  alias DeepEvalEx.TestRun.LocalStore

  @export_opts [:results_folder, :results_subfolder, :identifier, :hyperparameters]

  @doc """
  Evaluates test cases against one or more metrics, as deepeval's
  `evaluate()`.

  Returns `{:ok, %DeepEvalEx.EvaluationResult{}}` holding one
  `DeepEvalEx.TestResult` per test case, in the order of `test_cases`. Each
  carries the test case's fields, its metrics' `DeepEvalEx.Result`s as
  `:metrics_data` and whether it passed (`:success`).

  As deepeval's `evaluate()` with its default `ErrorConfig()`, a metric that
  errors raises: the exception the metric raised, or
  `DeepEvalEx.MetricError` (`DeepEvalEx.MissingTestCaseParamsError` for
  missing test case params) when it returned `{:error, reason}`, and no run
  is saved. With `ignore_errors: true` an errored metric is an errored
  result instead (see `DeepEvalEx.Result.error/3`), and with
  `skip_on_missing_params: true` a metric missing params is skipped (see
  "Errors" in `DeepEvalEx.Evaluator`). It never returns an error tuple.

  Test cases are evaluated concurrently, and so are the metrics of each test
  case (see `DeepEvalEx.Evaluator`). With `:results_folder` (or
  `config :deep_eval_ex, results_folder:` or the `DEEPEVAL_RESULTS_FOLDER`
  environment variable) set, the run is also saved in deepeval's format; see
  `evaluate_run/3`, which also returns the `DeepEvalEx.TestRun`.

  Raises `ArgumentError` when no metric has a threshold, as deepeval does
  (see `evaluate_run/3`).

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5); `nil` for
    score-only metrics
  - `:strict_mode` - Force every metric's threshold to `1` (default: false)
  - `:flaky` - Report every metric without letting it decide success
  - `:model` - LLM model to use for evaluation
  - `:max_concurrent` - Max test cases evaluated at once (default: 20);
    `:concurrency` is an alias
  - `:throttle_value` - Seconds to wait between launching test cases
    (default: 0)
  - `:run_async` - `false` evaluates test cases and their metrics one at a
    time (default: `true`); see "Concurrency" in `DeepEvalEx.Evaluator`
  - `:metric_concurrency` - Max metrics run at once within a test case
    (default: the number of metrics)
  - `:timeout` - Timeout in milliseconds (default: deepeval's per-task
    timeout, `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` or 180 seconds);
    the default for `:metric_timeout` and the minimum per-test-case timeout
  - `:metric_timeout` - Timeout per metric in milliseconds (default: the
    `:timeout` value). A slow metric errors while the test case's other
    metrics still complete
  - `:ignore_errors` - Record metric errors as errored results instead of
    raising them (default: `false`)
  - `:skip_on_missing_params` - Skip metrics whose test case lacks their
    required params (default: `false`)
  - `:results_folder`, `:results_subfolder`, `:identifier`,
    `:hyperparameters` - Save the run in deepeval's format, see
    `evaluate_run/3`

  ## Examples

      {:ok, %DeepEvalEx.EvaluationResult{test_results: [test_result]}} =
        DeepEvalEx.evaluate([test_case], [metric])

      test_result.success
      #=> true

      # With options
      {:ok, evaluation} =
        DeepEvalEx.evaluate(test_cases, [metric],
          threshold: 0.7,
          model: {:openai, "gpt-4o"},
          max_concurrent: 10
        )

  ## Deprecated: a single test case

  Passing a single `DeepEvalEx.TestCase` instead of a list still works for
  one release, with a deprecation warning, and returns the old
  `{:ok, [%DeepEvalEx.Result{}]}`. Wrap it in a list instead.
  """
  @spec evaluate([TestCase.t()], [module() | struct()], keyword()) ::
          {:ok, EvaluationResult.t()}
  @spec evaluate(TestCase.t(), [module() | struct()], keyword()) :: {:ok, [Result.t()]}
  def evaluate(test_cases, metrics, opts \\ [])

  def evaluate(test_cases, metrics, opts) when is_list(test_cases) do
    {results, _test_run, _path} = evaluate_run(test_cases, metrics, opts)
    {:ok, EvaluationResult.from_results(test_cases, results)}
  end

  def evaluate(%TestCase{} = test_case, metrics, opts) do
    IO.warn(
      "Passing a single test case to DeepEvalEx.evaluate/3 is deprecated and will be " <>
        "removed in the next release; pass a list, which returns " <>
        "{:ok, %DeepEvalEx.EvaluationResult{}}"
    )

    {[results], _test_run, _path} = evaluate_run([test_case], metrics, opts)
    {:ok, results}
  end

  @doc deprecated: "Use DeepEvalEx.evaluate/3, or evaluate_run/3 for the result lists"
  @doc """
  Evaluates test cases and returns their result lists, one per test case.

  Deprecated: use `evaluate/3`, which returns a
  `DeepEvalEx.EvaluationResult`, or `evaluate_run/3` for these result lists.
  Still works for one release, with a deprecation warning, and takes the
  options of `evaluate/3`.
  """
  @spec evaluate_batch([TestCase.t()], [module() | struct()], keyword()) :: [[Result.t()]]
  def evaluate_batch(test_cases, metrics, opts \\ []) do
    IO.warn(
      "DeepEvalEx.evaluate_batch/3 is deprecated and will be removed in the next release; " <>
        "use DeepEvalEx.evaluate/3, or evaluate_run/3 for the result lists"
    )

    {results, _test_run, _path} = evaluate_run(test_cases, metrics, opts)
    results
  end

  @doc """
  Evaluates test cases like `evaluate/3` and also returns the run as a
  `DeepEvalEx.TestRun`, saving it the way deepeval's `evaluate()` does.

  Returns `{results, test_run, path}`: one list of `DeepEvalEx.Result`s per
  test case, in the order of `test_cases` and of `metrics` (build a
  `DeepEvalEx.EvaluationResult` from them with
  `DeepEvalEx.EvaluationResult.from_results/2`), the run in deepeval's
  `TestRun` format and the path
  of the `test_run_<YYYYMMDD_HHMMSS>.json` file written, or `nil` when
  nothing was written.

  The file is written when `:results_folder`, `config :deep_eval_ex,
  results_folder:` or the `DEEPEVAL_RESULTS_FOLDER` environment variable is
  set (see `DeepEvalEx.TestRun.LocalStore`) and
  there is at least one test case. As in deepeval, failing to write it does
  not fail the evaluation: a warning is logged and `path` is `nil`.

  ## Options

  All `evaluate/3` options, including:

  - `:results_folder` - Folder to save the run in (default: the
    `:results_folder` setting, see `DeepEvalEx.Config`)
  - `:results_subfolder` - Subfolder of the results folder to save it in
  - `:identifier` - Name for the run
  - `:hyperparameters` - Keyword list or map of the settings that produced
    the outputs (model, prompt version, temperature, ...), recorded with
    stringified values; see `DeepEvalEx.TestRun.process_hyperparameters/1`

  These options are not passed on to the metrics.

  ## Thresholds

  As deepeval's `evaluate()`, raises `ArgumentError` before evaluating when
  no metric has a threshold or every metric with one is `:flaky`, since no
  test case could then pass or fail (see
  `DeepEvalEx.Evaluator.check_at_least_one_metric_has_threshold!/2`). So
  does `evaluate/3`. Metrics with a `nil` threshold are
  score-only: their results have `success: nil` and never decide a test
  case's success, nor do flaky metrics' results.

  ## Examples

      {results, test_run, path} =
        DeepEvalEx.evaluate_run(test_cases, [metric],
          results_folder: "eval_results",
          identifier: "nightly",
          hyperparameters: [model: "gpt-4o", temperature: 0.7]
        )
  """
  @spec evaluate_run([TestCase.t()], [module() | struct()], keyword()) ::
          {[[Result.t()]], TestRun.t(), Path.t() | nil}
  def evaluate_run(test_cases, metrics, opts \\ []) do
    {export_opts, eval_opts} = Keyword.split(opts, @export_opts)
    hyperparameters = TestRun.process_hyperparameters(export_opts[:hyperparameters])

    if metrics != [], do: Evaluator.check_at_least_one_metric_has_threshold!(metrics, eval_opts)

    started = System.monotonic_time()
    {results, durations} = Evaluator.evaluate_with_durations(test_cases, metrics, eval_opts)

    run_duration =
      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
        1_000_000

    test_run =
      TestRun.from_results(test_cases, results,
        run_durations: durations,
        run_duration: run_duration,
        identifier: export_opts[:identifier],
        hyperparameters: hyperparameters
      )

    {results, test_run, save_test_run(test_run, export_opts)}
  end

  defp save_test_run(%TestRun{test_cases: []}, _opts), do: nil

  defp save_test_run(test_run, opts) do
    case LocalStore.write(test_run, opts) do
      {:ok, path} ->
        Logger.info("Test run saved at #{path}")
        path

      :skip ->
        nil

      {:error, reason} ->
        Logger.warning("DeepEvalEx failed to save test run: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Get the configured default LLM model.
  """
  def default_model do
    Application.get_env(:deep_eval_ex, :default_model, {:openai, "gpt-4o-mini"})
  end

  @doc """
  Get the configured default threshold for pass/fail.
  """
  def default_threshold do
    Application.get_env(:deep_eval_ex, :default_threshold, 0.5)
  end
end
