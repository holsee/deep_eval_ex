# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/pattern_match/pattern_match.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.PatternMatch do
  @moduledoc """
  Pattern match metric checking that an LLM's whole output matches a
  regular expression.

  A port of deepeval 4.3.1's `PatternMatchMetric`. A non-LLM metric: it
  calls no judge and is fully deterministic.

  ## How It Works

  The pattern and the actual output are trimmed, then the pattern must match
  the **whole** output, as Python's `re.fullmatch`: the pattern is anchored
  as `\\A(?:pattern)\\z`, so `"yes|maybe"` must match all of `"maybe"`, and
  `"\\d{3}"` does not match `"1234"`.

  - `1.0` - The output fully matches the pattern
  - `0.0` - It does not

  Like Python's `str` patterns, the pattern is Unicode-aware: `\\w`, `\\d`,
  `\\s` and `\\b` match beyond ASCII. Patterns are compiled by PCRE (see
  `Regex`), whose syntax is close to Python's `re` but not identical; for
  instance Python's end-of-string `\\Z` is PCRE's `\\z`.

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.PatternMatch}

  test_case = TestCase.new!(
    input: "What is the store's phone number?",
    actual_output: "555-1234"
  )

  {:ok, result} = PatternMatch.measure(test_case, pattern: ~S"\\d{3}-\\d{4}")

  result.score   # => 1.0
  result.success # => true
  ```

  ## Options

  - `:pattern` - The regular expression the whole output must match, a
    string (required)
  - `:ignore_case` - Match case-insensitively (default: false)
  - `:threshold` - Minimum passing score (default: the float `1.0`, as
    deepeval's)
  - `:verbose_mode` - Compute the result's `:verbose_logs` and print them
    (default: false). Like deepeval's, it has no verbose logs otherwise

  Measuring without `:pattern` raises `ArgumentError`, and so does an
  invalid pattern, as deepeval's constructor raises `ValueError`
  (`"Invalid regex pattern: <pattern> — <error>"`).

  ## As a configured metric

  The pattern belongs to the metric, as in deepeval's
  `PatternMatchMetric(pattern=...)`. To evaluate with other metrics, or two
  patterns at once, build the metric with `new/1` and pass the struct to
  `DeepEvalEx.evaluate/3`; its fields take precedence over the run's
  options:

  ```elixir
  metric = PatternMatch.new(pattern: "yes|no", ignore_case: true)
  DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.ExactMatch])
  ```

  ## Eval Modes

  Like deepeval's, it ignores the eval mode (see
  `DeepEvalEx.SystemOne.Mode`): it measures the same way under `:hybrid`
  and `:system_one`, and builds and calls no System One model.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 1.0

  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.Python

  @enforce_keys [:pattern]
  defstruct [:pattern, :ignore_case, :threshold, :verbose_mode, :flaky]

  @type t :: %__MODULE__{
          pattern: String.t(),
          ignore_case: boolean() | nil,
          threshold: number() | nil,
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil
        }

  @doc """
  Creates a PatternMatch metric for `DeepEvalEx.evaluate/3`. See the
  moduledoc for the options; those left unset (`nil`) fall back to the
  run's options. The pattern is kept trimmed, as deepeval keeps it.

  Raises `ArgumentError`, as deepeval's constructor raises `ValueError`,
  when `:pattern` is missing or invalid.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {pattern, _regex} = compile!(opts)

    %__MODULE__{
      pattern: pattern,
      ignore_case: Keyword.get(opts, :ignore_case),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky)
    }
  end

  @impl true
  def metric_name, do: "Pattern Match"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `false`: PatternMatch takes no part in System One (see "Eval Modes").
  """
  @impl true
  def system_one?, do: false

  @doc """
  Measures whether the whole actual output matches `:pattern`.
  """
  def do_measure(test_case, opts) do
    {pattern, regex} = compile!(opts)
    threshold = BaseMetric.threshold(opts, default_threshold())
    actual = String.trim(test_case.actual_output)

    {score, reason} =
      if Regex.match?(regex, actual) do
        {1.0, "The actual output fully matches the pattern."}
      else
        {0.0, "The actual output does not match the pattern."}
      end

    {:ok,
     Result.new(
       metric: metric_name(),
       score: score,
       threshold: threshold,
       reason: reason,
       verbose_logs: verbose_logs(pattern, actual, score, reason, opts),
       metadata: %{pattern: pattern, ignore_case: ignore_case?(opts)}
     )}
  end

  # Like deepeval's, PatternMatch only builds its verbose logs in verbose mode.
  defp verbose_logs(pattern, actual, score, reason, opts) do
    if Verbose.verbose_mode?(opts) do
      Verbose.construct_verbose_logs(
        metric_name(),
        [
          "Pattern: #{pattern}",
          "Actual: #{actual}",
          "Score: #{Python.format_fixed(score, 2)}",
          "Reason: #{reason}"
        ],
        opts
      )
    end
  end

  defp ignore_case?(opts), do: Keyword.get(opts, :ignore_case, false) == true

  # deepeval's constructor: the trimmed pattern, compiled once on its own so
  # that only a valid pattern is accepted (`"a)(b"` is not, though it would
  # compile once wrapped), then anchored at both ends as `re.fullmatch`.
  # Python's `str` patterns are Unicode-aware, PCRE's are with `u`.
  # The error names the pattern as given, untrimmed, as deepeval's does.
  defp compile!(opts) do
    given =
      case Keyword.get(opts, :pattern) do
        given when is_binary(given) -> given
        _ -> raise ArgumentError, "PatternMatch requires a :pattern (a regular expression)."
      end

    pattern = String.trim(given)
    flags = if ignore_case?(opts), do: "ui", else: "u"

    with {:ok, _regex} <- Regex.compile(pattern, flags),
         {:ok, regex} <- Regex.compile("\\A(?:" <> pattern <> ")\\z", flags) do
      {pattern, regex}
    else
      {:error, {message, position}} ->
        raise ArgumentError,
              "Invalid regex pattern: #{given} — #{message} at position #{position}"
    end
  end
end
