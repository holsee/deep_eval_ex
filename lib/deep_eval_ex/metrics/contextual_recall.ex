# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/contextual_recall/contextual_recall.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ContextualRecall do
  @moduledoc """
  Contextual Recall metric for RAG retrieval coverage evaluation.

  Measures whether sentences in the expected output can be attributed
  to the retrieval context. This evaluates if the retrieved context
  contains all the information needed to produce the expected output.

  ## How It Works

  1. **Generate verdicts** - For each sentence in expected output, determine if it's:
     - `yes` - Can be attributed to nodes in retrieval context
     - `no` - Cannot be attributed to any context
  2. **Calculate score** - (attributed sentences) / (total sentences)
  3. **Higher score is better** - Success when score ≥ threshold

  ## Precision vs Recall

  - **ContextualPrecision**: Are retrieved nodes useful? (ranking quality)
  - **ContextualRecall**: Is expected output covered by context? (coverage)

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ContextualRecall}

  test_case = TestCase.new!(
    input: "What is the capital of France?",
    expected_output: "Paris is the capital of France. It is known for the Eiffel Tower.",
    retrieval_context: [
      "Paris is the capital city of France.",
      "The Eiffel Tower is located in Paris."
    ]
  )

  {:ok, result} = ContextualRecall.measure(test_case)
  result.score   # => 1.0 (all sentences attributable)
  result.success # => true (score >= threshold)
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Result}
  alias DeepEvalEx.Prompts.ContextualRecall, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualRecall, as: Schema

  @impl true
  def metric_name, do: "Contextual Recall"

  @impl true
  def required_params, do: [:input, :retrieval_context, :expected_output]

  @doc """
  Measures contextual recall of the expected output against retrieval context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    expected_output = test_case.expected_output
    retrieval_context = get_retrieval_context(test_case)

    with {:ok, verdicts} <- generate_verdicts(expected_output, retrieval_context, opts),
         score = calculate_score(verdicts),
         {:ok, reason} <- maybe_generate_reason(score, expected_output, verdicts, include_reason, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         metadata: %{
           verdicts: verdicts,
           sentence_count: length(verdicts),
           context_count: length(retrieval_context)
         }
       )}
    end
  end

  defp get_retrieval_context(%{retrieval_context: ctx}) when is_list(ctx), do: ctx
  defp get_retrieval_context(%{context: ctx}) when is_list(ctx), do: ctx
  defp get_retrieval_context(_), do: []

  defp generate_verdicts(_expected_output, [], _opts) do
    {:ok, []}
  end

  defp generate_verdicts(expected_output, retrieval_context, opts) do
    prompt =
      Template.generate_verdicts(
        expected_output: expected_output,
        retrieval_context: retrieval_context
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  defp calculate_score([]), do: 0.0

  defp calculate_score(verdicts) do
    total = length(verdicts)

    attributed_count =
      Enum.count(verdicts, fn %{verdict: v} ->
        v == :yes
      end)

    attributed_count / total
  end

  defp maybe_generate_reason(_score, _expected_output, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, expected_output, verdicts, true, opts) do
    {supportive, unsupportive} =
      Enum.split_with(verdicts, fn %{verdict: v} -> v == :yes end)

    supportive_reasons =
      supportive
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    unsupportive_reasons =
      unsupportive
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      Template.generate_reason(
        score: score,
        expected_output: expected_output,
        supportive_reasons: supportive_reasons,
        unsupportive_reasons: unsupportive_reasons
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
