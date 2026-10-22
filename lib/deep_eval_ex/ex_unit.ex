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

  - `assert_passes/2,3` - Assert metric evaluation passes (score >= threshold)
  - `assert_fails/2,3` - Assert metric evaluation fails (score < threshold)
  - `assert_score/3,4` - Assert score is within a range
  - `assert_evaluation/2,3` - Assert all metrics pass for a test case

  ## deepeval's `assert_test`

  `assert_evaluation(test_case, metrics)` is deepeval 4.3.1's
  `assert_test(test_case, metrics)`, and `assert_passes(test_case, metric)`
  is `assert_test(test_case, [metric])`:

  - Like `assert_test`, they raise `ArgumentError` unless at least one
    metric has a threshold and is not flaky (see
    `DeepEvalEx.Evaluator.check_at_least_one_metric_has_threshold!/2`).
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
  - A failing test case marked `flaky: true` does not flunk: as
    `assert_test`'s `warnings.warn`, it prints a warning (`IO.warn/1`)
    reading `"Flaky test case failed (no assertion raised): "` followed by
    that message, and the assertion returns its results.

  `assert_fails/2,3` and `assert_score/3,4` have no deepeval counterpart.
  They evaluate their metric through `DeepEvalEx.Evaluator.evaluate/3` too,
  with the same defaults, and keep their own messages.

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

  alias DeepEvalEx.{Config, Evaluator, Result, TestResult}
  alias DeepEvalEx.Metrics.Utils.Verbose

  # Settings the assertions read, as deepeval's assert_test.
  @settings [:verbose_mode, :ignore_errors, :skip_on_missing_params]

  # deepeval's assert_test evaluates with AsyncConfig(throttle_value=0,
  # max_concurrent=100).
  @max_concurrent 100
  @throttle_value 0

  @doc """
  Imports DeepEvalEx.ExUnit macros into your test module.

  ## Example

      defmodule MyTest do
        use ExUnit.Case
        use DeepEvalEx.ExUnit
      end
  """
  defmacro __using__(_opts) do
    quote do
      import DeepEvalEx.ExUnit
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
    [result] = assert_test(test_case, [metric], opts)
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
    [result] = evaluate(test_case, [metric], assert_opts(opts))
    result
  end

  # deepeval's assert_test reads its ErrorConfig and verbose mode from the
  # settings; an explicit option wins.
  defp assert_opts(opts) do
    Enum.reduce(@settings, opts, fn key, opts ->
      Keyword.put_new_lazy(opts, key, fn -> Config.get(key) end)
    end)
  end

  # The test case's results, evaluated with assert_test's AsyncConfig unless
  # the options say otherwise (`:concurrency` is `:max_concurrent`'s alias).
  defp evaluate(test_case, metrics, opts) do
    opts =
      if Keyword.has_key?(opts, :max_concurrent) or Keyword.has_key?(opts, :concurrency),
        do: opts,
        else: Keyword.put(opts, :max_concurrent, @max_concurrent)

    opts = Keyword.put_new(opts, :throttle_value, @throttle_value)

    [results] = Evaluator.evaluate([test_case], metrics, opts)
    results
  end

  # deepeval's assert_test: the test case fails as its TestResult does, and
  # a flaky test case only warns.
  defp assert_test(test_case, metrics, opts) do
    opts = assert_opts(opts)
    if metrics != [], do: Evaluator.check_at_least_one_metric_has_threshold!(metrics, opts)

    results = evaluate(test_case, metrics, opts)
    test_result = TestResult.new(test_case, results, 0)

    if test_result.success == false do
      message = assert_test_message(test_result.metrics_data)

      if test_case.flaky,
        do: IO.warn("Flaky test case failed (no assertion raised): " <> message),
        else: flunk!(message)
    end

    results
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
  def __assert_evaluation__(test_case, metrics, opts), do: assert_test(test_case, metrics, opts)

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
  # MetricData's fields in an f-string.
  defp assert_test_message(metrics_data) do
    failed =
      metrics_data
      |> Enum.filter(&(Result.errored?(&1) or &1.success != true))
      |> Enum.map_join(", ", &format_metric_data/1)

    "Metrics: #{failed} failed."
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
