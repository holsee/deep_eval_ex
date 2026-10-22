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
     Other verdicts are dropped.
  2. **Calculate score** - (attributed sentences) / (total verdicts), or `0`
     when there are none
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
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.ContextualRecall, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualRecall, as: Schema

  @impl true
  def metric_name, do: "Contextual Recall"

  @impl true
  def required_params, do: [:input, :retrieval_context, :expected_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  Measures contextual recall of the expected output against retrieval context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    expected_output = test_case.expected_output
    retrieval_context = test_case.retrieval_context

    with {:ok, verdicts} <- generate_verdicts(expected_output, retrieval_context, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(score, expected_output, verdicts, include_reason, opts) do
      # deepeval's verdicts carry the expected output they were judged
      # against (VerdictWithExpectedOutput).
      verdict_models = Verbose.verdict_models(verdicts, expected_output: expected_output)

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Verdicts:\n#{Verbose.prettify_list(verdict_models)}",
            "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
          ],
          opts
        )

      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{
           verdicts: verdicts,
           sentence_count: length(verdicts),
           context_count: length(retrieval_context)
         }
       )}
    end
  end

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

  # As in deepeval 4.3.1, no verdicts scores the integer 0
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      empty_score: 0,
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
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
