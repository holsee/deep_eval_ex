# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ExUnit do
  @moduledoc """
  ExUnit assertions for LLM evaluation.

  Provides macros for testing LLM outputs against evaluation metrics
  with detailed failure messages.

  ## Usage

  Add to your test file:

      defmodule MyApp.LLMTest do
        use ExUnit.Case
        use DeepEvalEx.ExUnit

        test "response is faithful to context" do
          test_case = DeepEvalEx.TestCase.new!(
            input: "What is the capital of France?",
            actual_output: "Paris is the capital of France.",
            retrieval_context: ["Paris is the capital city of France."]
          )

          assert_passes(test_case, DeepEvalEx.Metrics.Faithfulness)
        end
      end

  ## Available Assertions

  - `assert_test/2,3` - deepeval's `assert_test`: assert a test case passes
    its metrics, classifiers and expectations
  - `assert_trace/3,4` - deepeval's `assert_test(golden=..., metrics=...)`:
    assert that what a traced function did passes its trace and span
    metrics
  - `assert_passes/2,3` - Assert metric evaluation passes (score >= threshold)
  - `assert_fails/2,3` - Assert metric evaluation fails (score < threshold)
  - `assert_score/3,4` - Assert score is within a range
  - `assert_evaluation/2,3` - Assert all metrics pass for a test case

  ## deepeval's `assert_test`

  `assert_test(test_case, metrics, opts)` is deepeval 4.3.1's
  `assert_test(test_case, metrics, classifiers=...)`.
  `assert_evaluation(test_case, metrics)` is the same assertion, and
  `assert_passes(test_case, metric)` is `assert_test(test_case, [metric])`:

  - Like `assert_test`, they raise `ArgumentError` unless at least one
    metric has a threshold and is not flaky (see
    `DeepEvalEx.Evaluator.check_at_least_one_metric_has_threshold!/2`).
    With no metrics and no classifiers, `assert_evaluation(test_case, [])`
    judges the test case's expectations alone, and raises `ArgumentError`
    with the message of the `ValueError` `assert_test` raises for a test
    case without any: `"1 test case is missing expectations. ..."`. A test
    case with expectations needs no metric with a threshold.
  - A test case with expectations (see `DeepEvalEx.Dataset.Expectations`)
    is also judged against them, after its metrics, as `assert_test` adds
    its expectation evaluator: the `"Expectations"` result fails the test
    case, and is listed in the message, as a metric would be.
  - The test case is evaluated by `DeepEvalEx.Evaluator.evaluate/3`, so
    its metrics run concurrently, under the Evaluator's timeouts and
    `ErrorConfig` (see "Concurrency", "Timeouts" and "Errors" there).
    `:max_concurrent` defaults to `100` and `:throttle_value` to `0`, as
    `assert_test`'s `AsyncConfig`; every Evaluator option, `:run_async`,
    `:timeout` and `:metric_timeout` included, can be passed.
  - The test case fails as deepeval's `TestResult` does (see
    `DeepEvalEx.TestResult.new/4`): when a non-flaky metric failed. Failing
    flaky metrics and score-only metrics alone never fail it.
  - When it fails, the assertion flunks with `assert_test`'s message, which
    lists every errored or unsuccessful metric (flaky and score-only ones
    included) in the order of `metrics`, each field printed as Python's
    `str()` (`None`, `True`, floats as Python prints them):

        Metrics: Exact Match (score: 0.0, threshold: 1.0, strict: False, error: None, reason: The actual and expected outputs are different.) failed.

    An errored metric has `score: None` and `reason: None`, as deepeval's
    `MetricData` for an errored metric.
  - With a `classifiers:` option (`DeepEvalEx.Classifier`s), as
    `assert_test(..., classifiers=[...])`, the test case is also
    classified, and a classification that misses the test case's expected
    label fails it too (see `DeepEvalEx.TestResult.new/4`). The message
    then names the subject that failed, `"Metrics"`, `"Classifiers"` or
    `"Metrics and classifiers"`, and lists each failed classification
    after the metrics, as
    `name (label: ..., expected: ..., error: ..., reason: ...)`.
    `assert_evaluation(test_case, [], classifiers: [...])` checks
    classifiers alone, and needs no metric with a threshold.
  - A failing test case marked `flaky: true` does not flunk: as
    `assert_test`'s `warnings.warn`, it prints a warning (`IO.warn/1`)
    reading `"Flaky test case failed (no assertion raised): "` followed by
    that message, and the assertion returns its results.

  ## deepeval's `assert_test(golden=...)`

  `assert_trace(golden, metrics, fun)` is deepeval 4.3.1's trace-scoped
  `assert_test(golden=golden, metrics=metrics)`
  (`evaluate/execute/trace_scope.py`): `fun` runs your agent, instrumented
  with `DeepEvalEx.Tracing`, and what it did is evaluated against the
  golden.

      test "refund agent completes the task" do
        golden = %DeepEvalEx.Dataset.Golden{input: "Refund order 42", expected_output: "Refunded"}
        assert_trace golden, [DeepEvalEx.Metrics.ExactMatch], fn -> MyApp.Refunds.run(golden.input) end
      end

  - `fun` runs inside deepeval's wrapper span, the scope deepeval's pytest
    plugin opens around each test (`"__deepeval_internal_pytest_test_wrapper__"`),
    so every span it makes, in any process that joins its trace (see
    "Across processes" in `DeepEvalEx.Tracing`), is one trace. A `fun` that
    makes no span raises `DeepEvalEx.DeepEvalError` with deepeval's `"No
    active trace found for this test. ..."`; under `deepeval test run`
    deepeval would evaluate the bare wrapper instead.
  - The wrapper's first child is walked, as deepeval's sync iterator walks
    its root, with its metrics (see `DeepEvalEx.Evaluator.Agentic`'s
    `:trace_scope` mode). The trace errored when any top-level span did.
  - `metrics` are added to the trace's own
    (`DeepEvalEx.Tracing.update_current_trace/1`) and measured on the
    golden's input (`"None"` without one) and the trace's output (else the
    first span's), the golden filling the expected output, context,
    retrieval context and expected tools the trace has not set. A golden
    with expectations is also judged against them.
  - With no metric on the trace, its spans or the call, the golden must
    have expectations: otherwise `ArgumentError` is raised with
    `"1 test case is missing expectations. ..."`.
  - The test case fails when a non-flaky trace or span metric failed, and
    the assertion flunks with `assert_test`'s message, listing the failed
    trace-level metrics (span metrics fail the test case without being
    listed, as in deepeval). Errors follow the settings, as
    `assert_test/2,3`'s, and under `mix deep_eval.test` the test case is
    recorded in the run with its trace, named after the test unless the
    golden has a name.

  `assert_fails/2,3` and `assert_score/3,4` have no deepeval counterpart.
  They evaluate their metric through `DeepEvalEx.Evaluator.evaluate/3` too,
  with the same defaults, and keep their own messages. They are never
  recorded in a `mix deep_eval.test` run, where a passing test would
  otherwise show a failed metric.

  ## `mix deep_eval.test`

  Under `mix deep_eval.test` (deepeval's `deepeval test run`, see
  `Mix.Tasks.DeepEval.Test`) every `assert_test/2,3`,
  `assert_evaluation/2,3` and `assert_passes/2,3` also records its test case
  in the run's `DeepEvalEx.ExUnit.Collector`, as deepeval's `assert_test`
  adds it to the test run. The task then wraps the run up once the tests are
  done: the `Test Results` table, the summary and the saved run. In detail:

  - A test case without a `:name` is named after the ExUnit test that
    evaluated it, its full name (`"test refund policy answer"`,
    `"test describe block refund policy answer"`), as deepeval names it
    after the pytest test; the test is found from the asserting process or
    the process that started it (a `Task`).
  - The test-run cache is written, and with `--use-cache` (`-c`) read, as
    `assert_test` evaluates with `CacheConfig(write_cache=True,
    use_cache=should_use_cache())`; cache keys include the hyperparameters
    of `log_hyperparameters/1`.
  - A failing flaky test case's warning is kept for the run, and printed
    after it with `--show-warnings` (`-w`), instead of `IO.warn/1`.
  - `use DeepEvalEx.ExUnit` must come after `use ExUnit.Case`: it adds a
    `setup` that registers each test with the run, and replaces the
    imported `test` macros with `DeepEvalEx.ExUnit.Repeat`'s, which honour
    `--repeat`.

  Under plain `mix test` nothing is recorded, cached or saved, as under
  plain pytest.

  ## Errored Metrics

  A metric that cannot produce a score (missing test case parameters, LLM
  errors, timeouts, ...) is *errored*, not failed. As in deepeval's
  `assert_test`, the error is raised unless the `:ignore_errors` setting is
  on: `config :deep_eval_ex, ignore_errors: true` or, when that is not set,
  the `IGNORE_DEEPEVAL_ERRORS` environment variable (see `DeepEvalEx.Config`
  and "Errors" in `DeepEvalEx.Evaluator`). With it, `assert_passes/2,3` and
  `assert_evaluation/2,3` report the error in `assert_test`'s message
  (`error: <message>`), and `assert_fails/2,3` and `assert_score/3,4` flunk
  with a message of the form `"<Metric> metric errored: <message>"`, so
  errors are never mistaken for a low score.

  With the `:skip_on_missing_params` setting (`SKIP_DEEPEVAL_MISSING_PARAMS`)
  a metric whose test case lacks its required params is skipped instead: it
  neither passes nor fails `assert_passes/2,3` and `assert_evaluation/2,3`,
  which return its skipped result, while `assert_fails/2,3` and
  `assert_score/3,4` flunk as there is no score to check. An explicit
  `ignore_errors:` or `skip_on_missing_params:` option wins over both
  settings.

  ## Verbose mode

  As deepeval's `assert_test`, the assertions put every metric in verbose
  mode when the `:verbose_mode` setting is on, printing each metric's
  verbose logs (see `DeepEvalEx.Metrics.Utils.Verbose`). The setting is
  `config :deep_eval_ex, verbose_mode: true` or, when that is not set, the
  `DEEPEVAL_VERBOSE_MODE` environment variable set to a truthy value (`1`,
  `true`, `yes`, ...); see `DeepEvalEx.Config`. An explicit `verbose_mode:`
  option wins over both.
  """

  alias DeepEvalEx.{Classification, Config, DeepEvalError, Evaluator, Result, TestResult, TestRun}
  alias DeepEvalEx.Evaluator.{Agentic, Traced}
  alias DeepEvalEx.ExUnit.Collector
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Span, Trace}

  # Settings the assertions read, as deepeval's assert_test.
  @settings [:verbose_mode, :ignore_errors, :skip_on_missing_params]

  # deepeval's assert_test evaluates with AsyncConfig(throttle_value=0,
  # max_concurrent=100).
  @max_concurrent 100
  @throttle_value 0

  @doc """
  Imports DeepEvalEx.ExUnit macros into your test module.

  Must come after `use ExUnit.Case`, and raises `ArgumentError` otherwise:
  it also registers each test with a `mix deep_eval.test` run (see
  "`mix deep_eval.test`") and imports `DeepEvalEx.ExUnit.Repeat`'s `test`
  macros in place of `ExUnit.Case`'s.

  ## Example

      defmodule MyTest do
        use ExUnit.Case
        use DeepEvalEx.ExUnit
      end
  """
  defmacro __using__(_opts) do
    quote do
      DeepEvalEx.ExUnit.__check_case__!(__MODULE__)

      import ExUnit.Case, except: [test: 1, test: 2, test: 3]
      import DeepEvalEx.ExUnit.Repeat, only: [test: 1, test: 2, test: 3]
      import DeepEvalEx.ExUnit

      require ExUnit.Callbacks

      ExUnit.Callbacks.setup({DeepEvalEx.ExUnit.Collector, :register})
    end
  end

  @doc false
  def __check_case__!(module) do
    unless Module.has_attribute?(module, :ex_unit_setup) do
      raise ArgumentError,
            "use DeepEvalEx.ExUnit must come after use ExUnit.Case in #{inspect(module)}"
    end
  end

  @doc """
  Sets the hyperparameters of the `mix deep_eval.test` run, deepeval's
  `@log_hyperparameters`: saved with the run and part of every cache key
  of its test cases. Call it from `test/test_helper.exs`:

      ExUnit.start()
      DeepEvalEx.ExUnit.log_hyperparameters(%{"model" => "gpt-4.1", "prompt_version" => "v3"})

  Takes a map or keyword list (see
  `DeepEvalEx.TestRun.process_hyperparameters/1`). Does nothing under plain
  `mix test`.
  """
  @spec log_hyperparameters(keyword() | map()) :: :ok
  def log_hyperparameters(hyperparameters), do: Collector.log_hyperparameters(hyperparameters)

  @doc """
  Asserts that a test case passes its metrics, classifiers and
  expectations: deepeval's `assert_test(test_case, metrics,
  classifiers=...)`.

  See "deepeval's `assert_test`" in the module documentation for its
  failure message, flaky test cases and options, and "`mix deep_eval.test`"
  for how a run records it. Takes every `DeepEvalEx.Evaluator.evaluate/3`
  option, `:classifiers` included. Returns the metrics'
  `DeepEvalEx.Result`s, in the order of `metrics`.

  ## Examples

      assert_test(test_case, [Faithfulness, {AnswerRelevancy, threshold: 0.7}],
        classifiers: [DeepEvalEx.Classifiers.refusal()]
      )
  """
  defmacro assert_test(test_case, metrics, opts \\ []) do
    quote bind_quoted: [test_case: test_case, metrics: metrics, opts: opts] do
      DeepEvalEx.ExUnit.__assert_test__(test_case, metrics, opts)
    end
  end

  @doc """
  Asserts that what `fun` did, as traced by `DeepEvalEx.Tracing`, passes
  `metrics` and the metrics its trace and spans declare, judged against
  `golden`: deepeval's `assert_test(golden=golden, metrics=metrics)`.

  See "deepeval's `assert_test(golden=...)`" in the module documentation.
  Takes the options of `assert_test/3` (`:ignore_errors`,
  `:skip_on_missing_params`, `:verbose_mode`, `:model`, `:timeout`, ...)
  and returns the trace-level metrics' `DeepEvalEx.Result`s.

  ## Examples

      assert_trace golden, [DeepEvalEx.Metrics.ExactMatch], fn ->
        MyApp.Support.answer(golden.input)
      end
  """
  defmacro assert_trace(golden, metrics, fun, opts \\ []) do
    quote bind_quoted: [golden: golden, metrics: metrics, fun: fun, opts: opts] do
      DeepEvalEx.ExUnit.__assert_trace__(golden, metrics, fun, opts)
    end
  end

  @doc """
  Asserts that a test case passes the given metric.

  A test case passes when `score >= threshold`. This is deepeval's
  `assert_test(test_case, [metric])`: see "deepeval's `assert_test`" in the
  module documentation for its failure message, flaky test cases and
  options. Returns the metric's `DeepEvalEx.Result`.

  ## Examples

      # With default threshold (0.5)
      assert_passes(test_case, Faithfulness)

      # With custom threshold
      assert_passes(test_case, Faithfulness, threshold: 0.8)

      # With custom options
      assert_passes(test_case, GEval, threshold: 0.7, model: "gpt-4o")
  """
  defmacro assert_passes(test_case, metric, opts \\ []) do
    quote bind_quoted: [test_case: test_case, metric: metric, opts: opts] do
      DeepEvalEx.ExUnit.__assert_passes__(test_case, metric, opts)
    end
  end

  @doc """
  Asserts that a test case fails the given metric.

  A test case fails when `score < threshold`.

  ## Examples

      # Assert hallucination is detected
      assert_fails(test_case, Hallucination, threshold: 0.3)
  """
  defmacro assert_fails(test_case, metric, opts \\ []) do
    quote bind_quoted: [test_case: test_case, metric: metric, opts: opts] do
      DeepEvalEx.ExUnit.__assert_fails__(test_case, metric, opts)
    end
  end

  @doc """
  Asserts that a test case achieves a score within the given range.

  ## Examples

      # Assert score is at least 0.8
      assert_score(test_case, Faithfulness, min: 0.8)

      # Assert score is between 0.7 and 0.9
      assert_score(test_case, GEval, min: 0.7, max: 0.9)

      # Assert exact score (with delta tolerance)
      assert_score(test_case, ExactMatch, exact: 1.0)
  """
  defmacro assert_score(test_case, metric, score_opts, opts \\ []) do
    quote bind_quoted: [test_case: test_case, metric: metric, score_opts: score_opts, opts: opts] do
      DeepEvalEx.ExUnit.__assert_score__(test_case, metric, score_opts, opts)
    end
  end

  @doc """
  Asserts that a test case passes all given metrics.

  This is deepeval's `assert_test(test_case, metrics)`: see "deepeval's
  `assert_test`" in the module documentation for its failure message,
  flaky metrics and test cases and options. Returns the metrics'
  `DeepEvalEx.Result`s, in the order of `metrics`.

  ## Examples

      # Assert multiple metrics pass
      assert_evaluation(test_case, [Faithfulness, AnswerRelevancy])

      # With options
      assert_evaluation(test_case, [Faithfulness, Hallucination],
        threshold: 0.7,
        model: "gpt-4o"
      )
  """
  defmacro assert_evaluation(test_case, metrics, opts \\ []) do
    quote bind_quoted: [test_case: test_case, metrics: metrics, opts: opts] do
      DeepEvalEx.ExUnit.__assert_evaluation__(test_case, metrics, opts)
    end
  end

  # Internal implementation functions
  #
  # Every assertion evaluates through `DeepEvalEx.Evaluator.evaluate/3`: with
  # ignore_errors an erroring metric becomes an errored result, so errors are
  # reported as errors by every assertion instead of being mistaken for a
  # low score or an expected failure.

  @doc false
  def __assert_passes__(test_case, metric, opts) do
    [result] = __assert_test__(test_case, [metric], opts)
    result
  end

  @doc false
  def __assert_fails__(test_case, metric, opts) do
    result = run_metric(test_case, metric, opts)

    cond do
      Result.errored?(result) -> flunk!(format_errored_message(result))
      result.skipped -> flunk!(format_skipped_message(result))
      is_nil(result.success) -> flunk!(format_score_only_message(result))
      result.success -> flunk!(format_failure_message(result, :expected_fail))
      true -> result
    end
  end

  @doc false
  def __assert_score__(test_case, metric, score_opts, opts) do
    result = run_metric(test_case, metric, opts)

    cond do
      Result.errored?(result) -> flunk!(format_errored_message(result))
      result.skipped -> flunk!(format_skipped_message(result))
      true -> :ok
    end

    validate_score!(result, score_opts)
    result
  end

  defp run_metric(test_case, metric, opts) do
    {[result], _classifications, _duration} = evaluate(test_case, [metric], assert_opts(opts))
    result
  end

  # deepeval's assert_test reads its ErrorConfig and verbose mode from the
  # settings; an explicit option wins.
  defp assert_opts(opts) do
    Enum.reduce(@settings, opts, fn key, opts ->
      Keyword.put_new_lazy(opts, key, fn -> Config.get(key) end)
    end)
  end

  # The test case's results and classifications, evaluated with
  # assert_test's AsyncConfig unless the options say otherwise
  # (`:concurrency` is `:max_concurrent`'s alias).
  defp evaluate(test_case, metrics, opts) do
    opts =
      if Keyword.has_key?(opts, :max_concurrent) or Keyword.has_key?(opts, :concurrency),
        do: opts,
        else: Keyword.put(opts, :max_concurrent, @max_concurrent)

    opts = Keyword.put_new(opts, :throttle_value, @throttle_value)

    {[results], [classifications], [duration]} = Evaluator.run([test_case], metrics, opts)
    {results, classifications, duration}
  end

  @doc false
  # deepeval's assert_test: the test case fails as its TestResult does, and
  # a flaky test case only warns. In a mix deep_eval.test run it evaluates
  # with the run's cache and records the test case.
  def __assert_test__(test_case, metrics, opts) do
    opts = assert_opts(opts)
    check_metrics!(test_case, metrics, Keyword.get(opts, :classifiers, []), opts)

    running? = Collector.active?()
    opts = if running?, do: run_cache_opts(opts), else: opts

    {results, classifications, duration} = evaluate(test_case, metrics, opts)
    if running?, do: record(test_case, results, duration)

    # deepeval's assert_test builds its TestResult with index=None; only
    # :success, :metrics_data and :classifications are read here, so the
    # index is immaterial.
    test_result = TestResult.new(test_case, results, 0, classifications)

    if test_result.success == false do
      message = assert_test_message(test_result.metrics_data, test_result.classifications)
      warning = "Flaky test case failed (no assertion raised): " <> message

      cond do
        not test_case.flaky -> flunk!(message)
        running? -> Collector.warn(warning)
        true -> IO.warn(warning)
      end
    end

    results
  end

  @no_active_trace "No active trace found for this test. " <>
                     "`assert_test(golden=..., metrics=...)` must be called inside a " <>
                     "pytest test run with `deepeval test run`, and the test body must " <>
                     "invoke at least one `@observe`-decorated function."

  @doc false
  # trace_scope.py's _assert_test_from_current_trace, with `fun` run inside
  # the pytest plugin's wrapper span.
  def __assert_trace__(golden, metrics, fun, opts) when is_function(fun, 0) do
    opts = opts |> assert_opts() |> Keyword.delete(:metrics)
    {trace, user_spans} = trace_scope(fun)
    trace = %{trace | metrics: trace.metrics ++ metrics}

    if trace.metrics == [] and not Evaluator.has_expectations?(golden) and
         not Enum.any?(user_spans, &span_metrics?/1),
       do: Evaluator.validate_expectation_coverage!([golden])

    %{test_case: api_test_case, test_results: [test_result | _]} =
      Agentic.evaluate(trace, golden, [mode: :trace_scope, index: nil] ++ opts)

    if Collector.active?() do
      name = if is_nil(Map.get(golden, :name)), do: Collector.test_name(), else: golden.name
      Collector.record(%{api_test_case | name: name || api_test_case.name, order: nil})
    end

    if test_result.success == false,
      do: flunk!(assert_test_message(test_result.metrics_data, []))

    test_result.metrics_data
  end

  # {trace, top-level user spans}: the wrapper's trace as trace_scope reads
  # it mid-flight, errored when a top-level user span errored, with the
  # wrapper's first child as its one root. The wrapper's output stays nil,
  # as it has not exited yet.
  defp trace_scope(fun) do
    {nil, traces} =
      Tracing.capture([], fn ->
        Tracing.span(:base, [name: Traced.wrapper_name(), input: %{}], fn ->
          fun.()
          nil
        end)
      end)

    case traces do
      [%Trace{root_spans: [%Span{children: [first | _] = children}]} = trace | _] ->
        status = if Enum.any?(children, &(&1.status == :errored)), do: :errored, else: :success
        {%{trace | status: status, root_spans: [%{first | parent_uuid: nil}]}, children}

      _no_user_span ->
        raise DeepEvalError, message: @no_active_trace
    end
  end

  defp span_metrics?(%Span{metrics: [_ | _]}), do: true
  defp span_metrics?(%Span{children: children}), do: Enum.any?(children, &span_metrics?/1)

  # assert_test's CacheConfig(write_cache=get_is_running_deepeval(),
  # use_cache=should_use_cache()), keyed with the run's hyperparameters.
  defp run_cache_opts(opts) do
    opts
    |> Keyword.put_new_lazy(:cache, &Collector.cache/0)
    |> Keyword.put_new_lazy(:use_cache, fn -> Config.get(:use_cache) == true end)
    |> Keyword.put_new_lazy(:cache_hyperparameters, &Collector.cache_hyperparameters/0)
  end

  # deepeval's create_api_test_case(index=None) and update_test_run: named
  # after the test, without an order until the run is sorted, and with the
  # seconds it took as a float (update_run_duration), however short.
  defp record(test_case, results, duration) do
    test_run =
      TestRun.from_results([test_case], [results],
        run_durations: [duration],
        test_name: Collector.test_name()
      )

    case test_run.test_cases ++ test_run.conversational_test_cases do
      [api_test_case] ->
        Collector.record(%{
          api_test_case
          | order: test_case.dataset_rank,
            run_duration: duration / 1
        })

      [] ->
        :ok
    end
  end

  # deepeval's validate_assert_test_inputs: with no metrics and no
  # classifiers the test case must have expectations, which are then all
  # there is to judge. Classifiers alone, or expectations, need no metric
  # with a threshold.
  defp check_metrics!(test_case, [], [], _opts),
    do: Evaluator.validate_expectation_coverage!([test_case])

  defp check_metrics!(_test_case, [], _classifiers, _opts), do: :ok

  defp check_metrics!(test_case, metrics, _classifiers, opts) do
    if Evaluator.has_expectations?(test_case),
      do: :ok,
      else: Evaluator.check_at_least_one_metric_has_threshold!(metrics, opts)
  end

  defp validate_score!(result, score_opts) do
    min_score = Keyword.get(score_opts, :min)
    max_score = Keyword.get(score_opts, :max)
    exact_score = Keyword.get(score_opts, :exact)
    delta = Keyword.get(score_opts, :delta, 0.001)

    cond do
      exact_score != nil ->
        validate_exact_score!(result, exact_score, delta)

      min_score != nil and max_score != nil ->
        validate_range_score!(result, min_score, max_score)

      min_score != nil ->
        validate_min_score!(result, min_score)

      max_score != nil ->
        validate_max_score!(result, max_score)

      true ->
        flunk!("assert_score requires :min, :max, or :exact option")
    end
  end

  defp validate_exact_score!(result, expected, delta) do
    unless abs(result.score - expected) <= delta do
      flunk!(format_score_mismatch(result, :exact, expected, delta))
    end
  end

  defp validate_range_score!(result, min_score, max_score) do
    unless result.score >= min_score and result.score <= max_score do
      flunk!(format_score_mismatch(result, :range, {min_score, max_score}, nil))
    end
  end

  defp validate_min_score!(result, min_score) do
    unless result.score >= min_score do
      flunk!(format_score_mismatch(result, :min, min_score, nil))
    end
  end

  defp validate_max_score!(result, max_score) do
    unless result.score <= max_score do
      flunk!(format_score_mismatch(result, :max, max_score, nil))
    end
  end

  @doc false
  def __assert_evaluation__(test_case, metrics, opts),
    do: __assert_test__(test_case, metrics, opts)

  defp format_skipped_message(result) do
    """

    #{result.metric} was skipped: the test case lacks params it requires.

    Metric:    #{result.metric}
    Status:    SKIPPED (skip_on_missing_params)
    """
  end

  # Raises ExUnit.AssertionError with the given message
  # Note: ExUnit is a test dependency, so we suppress dialyzer warnings
  @dialyzer {:nowarn_function, flunk!: 1}
  defp flunk!(message) do
    raise ExUnit.AssertionError, message: message
  end

  # Formatting helpers

  # deepeval's assert_test message: every errored or unsuccessful metric
  # (`not metric_data.success`, so score-only ones too), each as
  # MetricData's fields in an f-string, then every failed classification;
  # the subject names what failed.
  defp assert_test_message(metrics_data, classifications) do
    failed_metrics = Enum.filter(metrics_data, &(Result.errored?(&1) or &1.success != true))
    failed_classifications = Enum.filter(classifications, &(&1.success == false))

    subject =
      cond do
        failed_metrics != [] and failed_classifications != [] -> "Metrics and classifiers"
        failed_classifications != [] -> "Classifiers"
        true -> "Metrics"
      end

    failed =
      Enum.map(failed_metrics, &format_metric_data/1) ++
        Enum.map(failed_classifications, &Classification.describe/1)

    "#{subject}: #{Enum.join(failed, ", ")} failed."
  end

  # create_metric_data leaves an errored metric's score and reason None.
  defp format_metric_data(result) do
    {score, reason} =
      if Result.errored?(result), do: {nil, nil}, else: {result.score, result.reason}

    "#{result.metric} (score: #{python_float(score)}, " <>
      "threshold: #{python_float(result.threshold)}, " <>
      "strict: #{Verbose.to_str(result.strict_mode)}, " <>
      "error: #{Verbose.to_str(result.error)}, reason: #{Verbose.to_str(reason)})"
  end

  # MetricData's score and threshold are pydantic floats: strict mode's
  # integer threshold 1 and clamped score 0 print as 1.0 and 0.0.
  defp python_float(number) when is_integer(number), do: Verbose.to_str(number * 1.0)
  defp python_float(value), do: Verbose.to_str(value)

  defp format_failure_message(result, :expected_fail) do
    """

    Metric evaluation passed unexpectedly.

    Metric:    #{result.metric}
    Score:     #{format_score(result.score)}
    Threshold: #{format_score(result.threshold)}
    Status:    PASS (expected FAIL)
    #{format_reason(result.reason)}
    """
  end

  defp format_score_mismatch(result, :exact, expected, delta) do
    """

    Score does not match expected value.

    Metric:   #{result.metric}
    Score:    #{format_score(result.score)}
    Expected: #{format_score(expected)} (±#{delta})
    #{format_reason(result.reason)}
    """
  end

  defp format_score_mismatch(result, :range, {min, max}, _delta) do
    """

    Score is outside expected range.

    Metric:   #{result.metric}
    Score:    #{format_score(result.score)}
    Expected: #{format_score(min)} - #{format_score(max)}
    #{format_reason(result.reason)}
    """
  end

  defp format_score_mismatch(result, :min, expected, _delta) do
    """

    Score is below minimum.

    Metric:   #{result.metric}
    Score:    #{format_score(result.score)}
    Minimum:  #{format_score(expected)}
    #{format_reason(result.reason)}
    """
  end

  defp format_score_mismatch(result, :max, expected, _delta) do
    """

    Score exceeds maximum.

    Metric:   #{result.metric}
    Score:    #{format_score(result.score)}
    Maximum:  #{format_score(expected)}
    #{format_reason(result.reason)}
    """
  end

  defp format_score_only_message(result) do
    """

    #{result.metric} has no threshold, so it can neither pass nor fail.

    Metric:    #{result.metric}
    Score:     #{format_score(result.score)}
    Status:    SCORED (no threshold)
    Use assert_score/3 to check the score of a score-only metric.
    """
  end

  defp format_errored_message(result) do
    """

    #{result.metric} metric errored: #{result.error}

    Metric:    #{result.metric}
    Threshold: #{format_score(result.threshold)}
    Status:    ERROR (no score was produced)
    #{format_error_hint(result.error)}
    """
  end

  # deepeval's MissingTestCaseParamsError messages (see DeepEvalEx.Result.error/3)
  defp format_error_hint(error) when is_binary(error) do
    if error =~ ~r/ cannot be (None|empty) for the '.*' metric$/s,
      do: "Ensure your TestCase includes all required fields for this metric.",
      else: ""
  end

  defp format_error_hint(_error), do: ""

  defp format_score(score) when is_float(score) do
    percentage = Float.round(score * 100, 1)
    "#{score} (#{percentage}%)"
  end

  defp format_score(score), do: inspect(score)

  defp format_reason(nil), do: ""
  defp format_reason(reason), do: "Reason:    #{reason}"
end
