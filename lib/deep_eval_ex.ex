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
      {:ok, results} = DeepEvalEx.evaluate(test_case, [metric])

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

  alias DeepEvalEx.{Evaluator, Result, TestCase, TestRun}
  alias DeepEvalEx.TestRun.LocalStore

  @export_opts [:results_folder, :results_subfolder, :identifier, :hyperparameters]

  @doc """
  Evaluate a single test case against one or more metrics.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:model` - LLM model to use for evaluation
  - `:timeout` - Timeout per metric in milliseconds (default: 60_000)
  - `:results_folder`, `:results_subfolder`, `:identifier`,
    `:hyperparameters` - Save the run in deepeval's format, see
    `evaluate_run/3`

  ## Examples

      {:ok, results} = DeepEvalEx.evaluate(test_case, [metric])

      # With options
      {:ok, results} = DeepEvalEx.evaluate(test_case, [metric],
        threshold: 0.7,
        model: {:openai, "gpt-4o"}
      )
  """
  @spec evaluate(TestCase.t(), [module() | struct()], keyword()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def evaluate(test_case, metrics, opts \\ []) do
    case evaluate_run([test_case], metrics, opts) do
      {[results], _test_run, _path} -> {:ok, results}
      {error, _test_run, _path} -> {:error, error}
    end
  end

  @doc """
  Evaluate multiple test cases against metrics concurrently.

  Leverages BEAM's lightweight processes for parallel evaluation.

  ## Options

  - `:concurrency` - Max test cases evaluated at once (default: schedulers * 2)
  - `:metric_concurrency` - Max metrics run at once within a test case
    (default: the number of metrics)
  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:model` - LLM model to use for evaluation
  - `:timeout` - Timeout in milliseconds (default: 60_000); the default for
    `:metric_timeout` and the minimum per-test-case timeout
  - `:metric_timeout` - Timeout per metric in milliseconds (default: the
    `:timeout` value). A slow metric yields an errored result while the
    test case's other metrics still complete

  The metrics of a test case run concurrently and results keep the order of
  `metrics`. See `DeepEvalEx.Evaluator` for how the timeouts interact.

  With `:results_folder` (or the `DEEPEVAL_RESULTS_FOLDER` environment
  variable) set, the run is also saved in deepeval's format; see
  `evaluate_run/3` for that and the `:results_subfolder`, `:identifier`
  and `:hyperparameters` options.

  ## Examples

      results = DeepEvalEx.evaluate_batch(test_cases, [metric1, metric2],
        concurrency: 20
      )
  """
  @spec evaluate_batch([TestCase.t()], [module() | struct()], keyword()) :: [[Result.t()]]
  def evaluate_batch(test_cases, metrics, opts \\ []) do
    {results, _test_run, _path} = evaluate_run(test_cases, metrics, opts)
    results
  end

  @doc """
  Evaluates test cases like `evaluate_batch/3` and returns the run as a
  `DeepEvalEx.TestRun`, saving it the way deepeval's `evaluate()` does.

  Returns `{results, test_run, path}`: the result lists of
  `evaluate_batch/3`, the run in deepeval's `TestRun` format and the path
  of the `test_run_<YYYYMMDD_HHMMSS>.json` file written, or `nil` when
  nothing was written.

  The file is written when `:results_folder` or the `DEEPEVAL_RESULTS_FOLDER`
  environment variable is set (see `DeepEvalEx.TestRun.LocalStore`) and
  there is at least one test case. As in deepeval, failing to write it does
  not fail the evaluation: a warning is logged and `path` is `nil`.

  ## Options

  All `evaluate_batch/3` options, plus:

  - `:results_folder` - Folder to save the run in (default: the
    `DEEPEVAL_RESULTS_FOLDER` environment variable)
  - `:results_subfolder` - Subfolder of the results folder to save it in
  - `:identifier` - Name for the run
  - `:hyperparameters` - Keyword list or map of the settings that produced
    the outputs (model, prompt version, temperature, ...), recorded with
    stringified values; see `DeepEvalEx.TestRun.process_hyperparameters/1`

  These options are not passed on to the metrics.

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

    started = System.monotonic_time()
    {results, durations} = Evaluator.evaluate_with_durations(test_cases, metrics, eval_opts)

    run_duration =
      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
        1_000_000

    test_run =
      TestRun.from_results(test_cases, results,
        metrics: metrics,
        strict_mode: Keyword.get(eval_opts, :strict_mode, false),
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
