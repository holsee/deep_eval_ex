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
  """

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

  A test case passes when `score >= threshold`.

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

  @doc false
  def __assert_passes__(test_case, metric, opts) do
    case metric.measure(test_case, opts) do
      {:ok, result} ->
        unless result.success do
          flunk!(format_failure_message(result, :expected_pass))
        end

        result

      {:error, reason} ->
        flunk!(format_error_message(metric, reason))
    end
  end

  @doc false
  def __assert_fails__(test_case, metric, opts) do
    case metric.measure(test_case, opts) do
      {:ok, result} ->
        if result.success do
          flunk!(format_failure_message(result, :expected_fail))
        end

        result

      {:error, reason} ->
        flunk!(format_error_message(metric, reason))
    end
  end

  @doc false
  def __assert_score__(test_case, metric, score_opts, opts) do
    case metric.measure(test_case, opts) do
      {:ok, result} ->
        validate_score!(result, score_opts)
        result

      {:error, reason} ->
        flunk!(format_error_message(metric, reason))
    end
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
  def __assert_evaluation__(test_case, metrics, opts) do
    results =
      Enum.map(metrics, fn metric ->
        {metric, metric.measure(test_case, opts)}
      end)

    failures =
      Enum.filter(results, fn
        {_metric, {:ok, result}} -> not result.success
        {_metric, {:error, _}} -> true
      end)

    if failures != [] do
      message = format_evaluation_failures(failures)
      flunk!(message)
    end

    Enum.map(results, fn {_metric, {:ok, result}} -> result end)
  end

  # Raises ExUnit.AssertionError with the given message
  # Note: ExUnit is a test dependency, so we suppress dialyzer warnings
  @dialyzer {:nowarn_function, flunk!: 1}
  defp flunk!(message) do
    raise ExUnit.AssertionError, message: message
  end

  # Formatting helpers

  defp format_failure_message(result, :expected_pass) do
    """

    Metric evaluation failed unexpectedly.

    Metric:    #{result.metric}
    Score:     #{format_score(result.score)}
    Threshold: #{format_score(result.threshold)}
    Status:    FAIL (expected PASS)
    #{format_reason(result.reason)}
    """
  end

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

  defp format_error_message(metric, {:missing_params, params}) do
    metric_name =
      if function_exported?(metric, :metric_name, 0) do
        metric.metric_name()
      else
        inspect(metric)
      end

    """

    Metric evaluation failed with error.

    Metric: #{metric_name}
    Error:  Missing required parameters: #{Enum.join(params, ", ")}

    Ensure your TestCase includes all required fields for this metric.
    """
  end

  defp format_error_message(metric, reason) do
    metric_name =
      if function_exported?(metric, :metric_name, 0) do
        metric.metric_name()
      else
        inspect(metric)
      end

    """

    Metric evaluation failed with error.

    Metric: #{metric_name}
    Error:  #{inspect(reason)}
    """
  end

  defp format_evaluation_failures(failures) do
    failure_details =
      Enum.map_join(failures, "\n", fn
        {_metric, {:ok, result}} ->
          """
            #{result.metric}:
              Score:     #{format_score(result.score)}
              Threshold: #{format_score(result.threshold)}
              #{format_reason(result.reason) |> String.trim() |> indent("    ")}
          """

        {metric, {:error, reason}} ->
          metric_name =
            if function_exported?(metric, :metric_name, 0) do
              metric.metric_name()
            else
              inspect(metric)
            end

          """
            #{metric_name}:
              Error: #{inspect(reason)}
          """
      end)

    """

    Multiple metric evaluations failed.

    Failures:
    #{failure_details}
    """
  end

  defp format_score(score) when is_float(score) do
    percentage = Float.round(score * 100, 1)
    "#{score} (#{percentage}%)"
  end

  defp format_score(score), do: inspect(score)

  defp format_reason(nil), do: ""
  defp format_reason(reason), do: "Reason:    #{reason}"

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> prefix <> line end)
  end
end
