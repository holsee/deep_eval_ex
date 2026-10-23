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
  - `DeepEvalEx.Metrics.PatternMatch` - Whole output matches a regular
    expression
  - `DeepEvalEx.Metrics.JsonCorrectness` - Output is JSON matching an
    expected JSON Schema
  - `DeepEvalEx.Metrics.GEval` - Flexible criteria-based evaluation
  - `DeepEvalEx.Metrics.Faithfulness` - RAG: claims supported by context
  - `DeepEvalEx.Metrics.Hallucination` - Detects unsupported statements
  - `DeepEvalEx.Metrics.AnswerRelevancy` - Response relevance to question
  - `DeepEvalEx.Metrics.ContextualPrecision` - RAG retrieval ranking quality
  - `DeepEvalEx.Metrics.ContextualRecall` - RAG coverage of ground truth
  - `DeepEvalEx.Metrics.ContextualRelevancy` - RAG relevance of the
    retrieved context to the input
  - `DeepEvalEx.Metrics.Bias` - Gender, political, racial/ethnic and
    geographical bias in the output's opinions
  - `DeepEvalEx.Metrics.Toxicity` - Personal attacks, mockery, hate,
    dismissive statements and threats in the output's opinions
  - `DeepEvalEx.Metrics.PIILeakage` - Personally identifiable information
    and privacy-sensitive data in the output
  - `DeepEvalEx.Metrics.PromptAlignment` - Whether the output follows the
    prompt template's instructions
  - `DeepEvalEx.Metrics.Summarization` - Whether a summary is faithful to,
    and covers, its original text
  - `DeepEvalEx.Metrics.ToolCorrectness` - Agent tool calls against the
    expected tools
  - `DeepEvalEx.Metrics.ArgumentCorrectness` - Whether each agent tool
    call's arguments address the input
  - `DeepEvalEx.Metrics.ToolPermission` - Agent tool calls against an
    allowlist and denylist
  - `DeepEvalEx.Metrics.JevEval` - Your own weighted questions, decided by
    a System One model (Jev)

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

  alias DeepEvalEx.{Config, EvaluationResult, Evaluator, Result, TestCase, TestRun}
  alias DeepEvalEx.TestRun.Cache.Store
  alias DeepEvalEx.TestRun.LocalStore

  @export_opts [
    :results_folder,
    :results_subfolder,
    :cache_folder,
    :identifier,
    :hyperparameters,
    :dataset_alias,
    :dataset_id,
    :dataset_version
  ]

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
  (see `evaluate_run/3`). Test cases with expectations are also judged
  against them (see "Expectations" in `evaluate_run/3`).

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
  - `:classifiers` - `DeepEvalEx.Classifier`s to run on every test case
    after its metrics (see `DeepEvalEx.Classifiers` for deepeval's
    built-ins); their `DeepEvalEx.Classification`s are each
    `DeepEvalEx.TestResult`'s `:classifications`, and decide its success
    with the metrics (see "Classifiers" in `evaluate_run/3`)
  - `:results_folder`, `:results_subfolder`, `:identifier`,
    `:hyperparameters` - Save the run in deepeval's format, see
    `evaluate_run/3`
  - `:use_cache`, `:write_cache`, `:cache_folder` - The test-run cache, see
    "Cache" in `evaluate_run/3`

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
    {results, classifications, _test_run, _path} = run(test_cases, metrics, opts)
    {:ok, EvaluationResult.from_results(test_cases, results, classifications)}
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
  nothing was written. `DeepEvalEx.ConversationalTestCase`s evaluated with
  conversational metrics are exported as the run's
  `conversationalTestCases` (see `DeepEvalEx.TestRun.from_results/3`).

  The file is written when `:results_folder`, `config :deep_eval_ex,
  results_folder:` or the `DEEPEVAL_RESULTS_FOLDER` environment variable is
  set (see `DeepEvalEx.TestRun.LocalStore`) and
  there is at least one test case. As in deepeval, failing to write it does
  not fail the evaluation: a warning is logged and `path` is `nil`.

  Every run with at least one test case also overwrites
  `.deepeval/.latest_run_full.json` (the same content) and
  `.deepeval/.latest_test_run.json` (`{"testRunData": ...}`), as deepeval's
  `save_test_run_locally` and `wrap_up_test_run` do, unless
  `DEEPEVAL_FILE_SYSTEM=READ_ONLY`; see "Latest-run snapshots" in
  `DeepEvalEx.TestRun.LocalStore`. A snapshot that cannot be written only
  logs a warning. An invalid `DEEPEVAL_FILE_SYSTEM` raises `ArgumentError`
  before evaluating.

  The run also writes the test-run cache, `.deepeval/.deepeval-cache.json`
  (see "Cache").

  ## Options

  All `evaluate/3` options, including:

  - `:results_folder` - Folder to save the run in (default: the
    `:results_folder` setting, see `DeepEvalEx.Config`)
  - `:results_subfolder` - Subfolder of the results folder to save it in
  - `:identifier` - Name for the run
  - `:hyperparameters` - Keyword list or map of the settings that produced
    the outputs (model, prompt version, temperature, ...), recorded with
    stringified values; see `DeepEvalEx.TestRun.process_hyperparameters/1`
  - `:dataset_alias`, `:dataset_id`, `:dataset_version` - The dataset the
    test cases came from, written as `datasetAlias`, `datasetId` and
    `datasetVersion`, as deepeval takes them from its test cases (default:
    `nil`); `DeepEvalEx.Dataset.EvaluationDataset.evaluate_run/4` sets them
  - `:cache_folder` - The folder of the `.deepeval` snapshots and the
    test-run cache (default: the `:cache_folder` setting, see
    `DeepEvalEx.Config`)
  - `:use_cache` - Reuse cached results (default: `false`), see "Cache"
  - `:write_cache` - Write the test-run cache (default: `true`); `false`
    deletes it, see "Cache"

  These options are not passed on to the metrics.

  ## Cache

  As deepeval's `evaluate()` with its default `CacheConfig`, every run
  writes the test-run cache, `.deepeval-cache.json` in the cache folder:
  the error-free results and classifications of each single-turn test case,
  keyed by the test case, with each metric's configuration (see
  `DeepEvalEx.TestRun.Cache`). The file is deepeval's, so either can read
  the other's. After a run it holds that run's entries only; while it runs,
  `.temp-deepeval-cache.json` holds them too. A run with classifiers only
  has no test run to wrap up, as in deepeval: its entries are added to the
  cache file, and the temp file is left.

  With `use_cache: true` a metric whose result is cached for the same test
  case and configuration is not measured again: its result is the cached
  one, at cost `0.0` (see "Cache" in `DeepEvalEx.Evaluator`). deepeval's
  `evaluate()` does not read the `ENABLE_DEEPEVAL_CACHE` setting, and
  neither does this. With `write_cache: false` the cache is neither read
  nor written, and both files are deleted.

  ## Classifiers

  With `:classifiers` every test case is also classified (see
  "Classifiers" in `DeepEvalEx.Evaluator`). The classifiers are checked
  against the test cases' `expected_labels` before anything is evaluated
  (`DeepEvalEx.Classifier.Utils.validate!/2`). Classifications are local,
  as deepeval's: `evaluate/3` folds them into each
  `DeepEvalEx.TestResult`'s success, but they are never part of the
  `DeepEvalEx.TestRun`, whose test cases' success comes from the metrics
  alone. A run with classifiers, no metrics and no expectations has no test
  run, as deepeval's classifier-only `evaluate()`: it returns
  `{results, nil, nil}` (each result list empty) and writes nothing.

  ## Expectations

  A test case with expectations (`:expectations`, see
  `DeepEvalEx.Dataset.Expectations`) is judged against them after its
  metrics: its result list ends with an `"Expectations"` result, which
  decides its success as a metric does (see "Expectations" in
  `DeepEvalEx.Evaluator`). The test run exports it as the test case's
  `expectationsData`, not in `metricsData` or `metricsScores` (see
  `DeepEvalEx.TestRun.ExpectationsData`).

  Expectations alone are enough to evaluate, without metrics or
  classifiers; every test case then needs some, as deepeval's
  `validate_expectation_coverage` requires: otherwise `ArgumentError` is
  raised before evaluating with deepeval's message, `"1 test case is
  missing expectations. ..."` (see
  `DeepEvalEx.Evaluator.validate_expectation_coverage!/1`).

  ## Thresholds

  As deepeval's `evaluate()`, raises `ArgumentError` before evaluating when
  no metric has a threshold or every metric with one is `:flaky`, since no
  test case could then pass or fail (see
  `DeepEvalEx.Evaluator.check_at_least_one_metric_has_threshold!/2`), unless
  a test case has expectations, which can. So does `evaluate/3`. Metrics with a `nil` threshold are
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
  @spec evaluate_run(
          [TestCase.t() | DeepEvalEx.ConversationalTestCase.t()],
          [module() | struct()],
          keyword()
        ) ::
          {[[Result.t()]], TestRun.t() | nil, Path.t() | nil}
  def evaluate_run(test_cases, metrics, opts \\ []) do
    {results, _classifications, test_run, path} = run(test_cases, metrics, opts)
    {results, test_run, path}
  end

  @doc false
  # evaluate_run/3, also returning the classifications:
  # {results, classifications, test_run, path}.
  @spec run(
          [TestCase.t() | DeepEvalEx.ConversationalTestCase.t()],
          [module() | struct()],
          keyword()
        ) ::
          {[[Result.t()]], [[DeepEvalEx.Classification.t()]], TestRun.t() | nil, Path.t() | nil}
  def run(test_cases, metrics, opts) do
    {export_opts, eval_opts} = Keyword.split(opts, @export_opts)
    hyperparameters = TestRun.process_hyperparameters(export_opts[:hyperparameters])

    classifiers = Keyword.get(eval_opts, :classifiers, [])
    expectations? = Enum.any?(test_cases, &Evaluator.has_expectations?/1)

    # deepeval's validate_evaluate_inputs, check_valid_test_cases_type, then
    # the threshold check, which expectations make unnecessary.
    if metrics == [] and classifiers == [],
      do: Evaluator.validate_expectation_coverage!(test_cases)

    Evaluator.check_valid_test_cases_type!(test_cases)

    if metrics != [] and not expectations?,
      do: Evaluator.check_at_least_one_metric_has_threshold!(metrics, eval_opts)

    # Read before evaluating so an invalid DEEPEVAL_FILE_SYSTEM fails fast, as
    # deepeval fails to load its settings, rather than after the LLM calls.
    export_opts = Keyword.put(export_opts, :read_only, Config.read_only?())

    {:ok, cache} =
      Store.start_link(
        write_cache: Keyword.get(eval_opts, :write_cache, true),
        folder: presence(export_opts[:cache_folder]) || Config.get(:cache_folder),
        read_only: export_opts[:read_only]
      )

    try do
      evaluate_and_export(test_cases, metrics, eval_opts, export_opts, hyperparameters, cache)
    after
      Store.stop(cache)
    end
  end

  defp evaluate_and_export(test_cases, metrics, eval_opts, export_opts, hyperparameters, cache) do
    classifiers = Keyword.get(eval_opts, :classifiers, [])
    expectations? = Enum.any?(test_cases, &Evaluator.has_expectations?/1)
    eval_opts = Keyword.merge(eval_opts, cache: cache, use_cache: use_cache?(eval_opts))

    started = System.monotonic_time()
    {results, classifications, durations} = Evaluator.run(test_cases, metrics, eval_opts)

    run_duration =
      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
        1_000_000

    if metrics == [] and classifiers != [] and not expectations? do
      # deepeval's classifier-only run: classifications are local only, so
      # there is no test run to finalize or save.
      {results, classifications, nil, nil}
    else
      test_run =
        export(test_cases, results, durations, run_duration, hyperparameters, export_opts)

      {results, classifications, test_run, save_test_run(test_run, export_opts, cache)}
    end
  end

  # deepeval's evaluate() reads the cache only when its CacheConfig says so.
  defp use_cache?(eval_opts), do: Keyword.get(eval_opts, :use_cache, false) == true

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp export(test_cases, results, durations, run_duration, hyperparameters, export_opts) do
    TestRun.from_results(test_cases, results,
      run_durations: durations,
      run_duration: run_duration,
      identifier: export_opts[:identifier],
      hyperparameters: hyperparameters,
      dataset_alias: export_opts[:dataset_alias],
      dataset_id: export_opts[:dataset_id],
      dataset_version: export_opts[:dataset_version]
    )
  end

  defp save_test_run(%TestRun{test_cases: [], conversational_test_cases: []}, _opts, _cache),
    do: nil

  # deepeval's save_test_run_locally (rolling snapshot, then the results
  # folder), then wrap_up_test_run's cache wrap-up and
  # LATEST_TEST_RUN_FILE_PATH.
  defp save_test_run(test_run, opts, cache) do
    warn_on_error(LocalStore.write_rolling(test_run, opts), "write rolling snapshot to")
    Store.wrap_up(cache)
    path = save_to_results_folder(test_run, opts)
    warn_on_error(LocalStore.write_latest(test_run, opts), "write")
    path
  end

  defp warn_on_error({:error, {path, reason}}, action) do
    Logger.warning("DeepEvalEx failed to #{action} #{path}: #{inspect(reason)}")
  end

  defp warn_on_error(_ok_or_skip, _action), do: :ok

  defp save_to_results_folder(test_run, opts) do
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
