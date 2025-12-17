# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/answer_relevancy/answer_relevancy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.AnswerRelevancy do
  @moduledoc """
  Answer Relevancy metric for evaluating response quality.

  Measures whether the statements in an LLM's output are relevant
  to addressing the input question. This metric evaluates the
  appropriateness and focus of responses.

  ## How It Works

  1. **Extract statements** - Identify statements from the actual output
  2. **Generate verdicts** - For each statement, determine if it's:
     - `yes` - Relevant to addressing the input
     - `no` - Irrelevant to the input
     - `idk` - Ambiguous (supporting information)
  3. **Calculate score** - (relevant + ambiguous) / total statements
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.AnswerRelevancy}

  test_case = TestCase.new!(
    input: "What are the features of the new laptop?",
    actual_output: "The laptop has a Retina display and 12-hour battery life."
  )

  {:ok, result} = AnswerRelevancy.measure(test_case)
  result.score   # => 1.0 (all statements are relevant)
  result.success # => true (score >= threshold)
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Result}
  alias DeepEvalEx.Prompts.AnswerRelevancy, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.AnswerRelevancy, as: Schema

  @impl true
  def metric_name, do: "Answer Relevancy"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  Measures answer relevancy of the actual output to the input.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    input = test_case.input
    actual_output = test_case.actual_output

    with {:ok, statements} <- generate_statements(actual_output, opts),
         {:ok, verdicts} <- generate_verdicts(input, statements, opts),
         score = calculate_score(verdicts),
         {:ok, reason} <- maybe_generate_reason(score, input, verdicts, include_reason, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         metadata: %{
           statements: statements,
           verdicts: verdicts,
           statement_count: length(statements)
         }
       )}
    end
  end

  defp generate_statements(actual_output, opts) do
    prompt = Template.generate_statements(actual_output: actual_output)

    case Adapter.generate_with_schema(prompt, Schema.statements_schema(), opts) do
      {:ok, response} -> Schema.parse_statements(response)
      {:error, _} = error -> error
    end
  end

  defp generate_verdicts(_input, [], _opts) do
    # No statements means nothing to evaluate
    {:ok, []}
  end

  defp generate_verdicts(input, statements, opts) do
    prompt =
      Template.generate_verdicts(
        input: input,
        statements: statements
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  defp calculate_score([]), do: 1.0

  defp calculate_score(verdicts) do
    total = length(verdicts)

    # Count relevant statements (yes and idk count as relevant)
    relevant_count =
      Enum.count(verdicts, fn %{verdict: v} ->
        v != :no
      end)

    relevant_count / total
  end

  defp maybe_generate_reason(_score, _input, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, input, verdicts, true, opts) do
    # Collect reasons from irrelevant verdicts
    irrelevant_statements =
      verdicts
      |> Enum.filter(fn %{verdict: v} -> v == :no end)
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      Template.generate_reason(
        score: score,
        input: input,
        irrelevant_statements: irrelevant_statements
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
