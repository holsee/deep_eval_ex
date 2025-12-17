defmodule DeepEvalEx.Metrics.ExactMatch do
  @moduledoc """
  Exact match metric for comparing LLM output to expected output.

  This is a simple, non-LLM metric that checks if the actual output
  exactly matches the expected output (after trimming whitespace).

  ## Usage

      metric = DeepEvalEx.Metrics.ExactMatch

      test_case = %DeepEvalEx.TestCase{
        input: "What is 2 + 2?",
        actual_output: "4",
        expected_output: "4"
      }

      {:ok, result} = metric.measure(test_case)
      # => %DeepEvalEx.Result{score: 1.0, success: true, ...}

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 1.0)
  - `:case_sensitive` - Whether comparison is case-sensitive (default: true)
  - `:normalize_whitespace` - Collapse multiple whitespace to single space (default: false)

  ## Score Interpretation

  - `1.0` - Exact match
  - `0.0` - No match
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 1.0

  @impl true
  def metric_name, do: "ExactMatch"

  @impl true
  def required_params, do: [:input, :actual_output, :expected_output]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    normalize_ws = Keyword.get(opts, :normalize_whitespace, false)

    expected = normalize(test_case.expected_output, case_sensitive, normalize_ws)
    actual = normalize(test_case.actual_output, case_sensitive, normalize_ws)

    {score, reason} =
      if expected == actual do
        {1.0, "The actual and expected outputs are exact matches."}
      else
        {0.0, "The actual and expected outputs are different."}
      end

    result =
      Result.new(
        metric: metric_name(),
        score: score,
        threshold: threshold,
        reason: reason,
        metadata: %{
          expected: test_case.expected_output,
          actual: test_case.actual_output,
          case_sensitive: case_sensitive,
          normalize_whitespace: normalize_ws
        }
      )

    {:ok, result}
  end

  defp normalize(text, case_sensitive, normalize_whitespace) do
    text = String.trim(text)

    text =
      if normalize_whitespace do
        text
        |> String.replace(~r/\s+/, " ")
      else
        text
      end

    if case_sensitive do
      text
    else
      String.downcase(text)
    end
  end
end
