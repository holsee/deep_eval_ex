# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/hallucination/hallucination.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Hallucination do
  @moduledoc """
  Hallucination metric for detecting unsupported statements.

  Measures whether the actual output contradicts the provided context.
  Unlike Faithfulness which extracts claims and truths separately,
  Hallucination directly compares the output against each context item.

  ## How It Works

  1. **Generate verdicts** - For each context, determine if the output:
     - `yes` - Agrees with the context (factual alignment)
     - `no` - Contradicts the context (hallucination)
  2. **Calculate score** - (contradictions) / (total contexts)
  3. **Lower score is better** - Success when score ≤ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.Hallucination}

  test_case = TestCase.new!(
    input: "What year did Einstein win the Nobel Prize?",
    actual_output: "Einstein won the Nobel Prize in 1969.",
    context: [
      "Einstein won the Nobel Prize in 1921.",
      "Einstein won it for his discovery of the photoelectric effect."
    ]
  )

  {:ok, result} = Hallucination.measure(test_case)
  result.score   # => 0.5 (1 contradiction out of 2 contexts)
  result.success # => true (0.5 <= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5, lower is better)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Result}
  alias DeepEvalEx.Prompts.Hallucination, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Hallucination, as: Schema

  @impl true
  def metric_name, do: "Hallucination"

  @impl true
  def required_params, do: [:input, :actual_output, :context]

  @doc """
  Measures hallucination of the actual output against context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    contexts = get_contexts(test_case)
    actual_output = test_case.actual_output

    with {:ok, verdicts} <- generate_verdicts(actual_output, contexts, opts),
         score = calculate_score(verdicts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, include_reason, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         success: score <= threshold,
         reason: reason,
         metadata: %{
           verdicts: verdicts,
           context_count: length(contexts)
         }
       )}
    end
  end

  defp get_contexts(%{context: ctx}) when is_list(ctx), do: ctx
  defp get_contexts(%{retrieval_context: ctx}) when is_list(ctx), do: ctx
  defp get_contexts(_), do: []

  defp generate_verdicts(_actual_output, [], _opts) do
    # No contexts means no hallucinations possible
    {:ok, []}
  end

  defp generate_verdicts(actual_output, contexts, opts) do
    prompt =
      Template.generate_verdicts(
        actual_output: actual_output,
        contexts: contexts
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  defp calculate_score([]), do: 0.0

  defp calculate_score(verdicts) do
    total = length(verdicts)

    hallucination_count =
      Enum.count(verdicts, fn %{verdict: v} ->
        v == :no
      end)

    hallucination_count / total
  end

  defp maybe_generate_reason(_score, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, verdicts, true, opts) do
    {alignments, contradictions} =
      Enum.split_with(verdicts, fn %{verdict: v} -> v == :yes end)

    alignment_reasons =
      alignments
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    contradiction_reasons =
      contradictions
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      Template.generate_reason(
        score: score,
        factual_alignments: alignment_reasons,
        contradictions: contradiction_reasons
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
