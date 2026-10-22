# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/faithfulness/faithfulness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Faithfulness do
  @moduledoc """
  Faithfulness metric for RAG evaluation.

  Measures whether the claims in an LLM's output are supported by
  the retrieval context. Essential for evaluating RAG pipelines
  to ensure responses are grounded in retrieved information.

  ## How It Works

  1. **Extract claims** - Identify factual claims from the actual output
  2. **Extract truths** - Identify facts from the retrieval context
  3. **Generate verdicts** - For each claim, determine if it's:
     - `yes` - Supported by the context
     - `no` - Contradicts the context
     - `borderline` - Cannot be verified (not mentioned); a judge's legacy
       `idk` reads as `borderline`, and other verdicts are dropped
  4. **Calculate score** - (supported + borderline claims) / total verdicts,
     or `1` when there are none

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.Faithfulness}

  test_case = TestCase.new!(
    input: "What is the company's vacation policy?",
    actual_output: "Employees get 20 days of PTO per year.",
    retrieval_context: [
      "Section 3.2: Full-time employees receive 20 days paid time off annually.",
      "Section 3.3: PTO can be carried over up to 5 days."
    ]
  )

  {:ok, result} = Faithfulness.measure(test_case)
  result.score   # => 1.0 (claim is supported)
  result.reason  # => "All claims are supported by the context..."
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:truths_extraction_limit` - Max truths to extract per doc (default: nil = all)
  - `:model` - LLM model for evaluation
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, LLM.Usage, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Prompts.Faithfulness, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Faithfulness, as: Schema

  @impl true
  def metric_name, do: "Faithfulness"

  @impl true
  def required_params, do: [:input, :actual_output, :retrieval_context]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  Measures faithfulness of the actual output against retrieval context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:truths_extraction_limit` - Max truths to extract (default: nil)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)
    truths_limit = Keyword.get(opts, :truths_extraction_limit)

    retrieval_context = get_retrieval_context(test_case)
    actual_output = test_case.actual_output

    # Run truths and claims extraction concurrently; Usage.async/1 carries
    # the tasks' token usage back into this metric's usage scope.
    truths_task =
      Usage.async(fn ->
        generate_truths(retrieval_context, truths_limit, opts)
      end)

    claims_task =
      Usage.async(fn ->
        generate_claims(actual_output, opts)
      end)

    with {:ok, truths} <- Usage.await(truths_task, 60_000),
         {:ok, claims} <- Usage.await(claims_task, 60_000),
         {:ok, verdicts} <- generate_verdicts(claims, truths, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, include_reason, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         metadata: %{
           truths: truths,
           claims: claims,
           verdicts: verdicts,
           truths_extraction_limit: truths_limit
         }
       )}
    end
  end

  defp get_retrieval_context(%{retrieval_context: ctx}) when is_list(ctx), do: ctx
  defp get_retrieval_context(%{context: ctx}) when is_list(ctx), do: ctx
  defp get_retrieval_context(_), do: []

  defp generate_truths(retrieval_context, limit, opts) do
    context_text = Enum.join(retrieval_context, "\n\n")

    prompt =
      Template.generate_truths(
        retrieval_context: context_text,
        extraction_limit: limit
      )

    case Adapter.generate_with_schema(prompt, Schema.truths_schema(), opts) do
      {:ok, response} -> Schema.parse_truths(response)
      {:error, _} = error -> error
    end
  end

  defp generate_claims(actual_output, opts) do
    prompt = Template.generate_claims(actual_output: actual_output)

    case Adapter.generate_with_schema(prompt, Schema.claims_schema(), opts) do
      {:ok, response} -> Schema.parse_claims(response)
      {:error, _} = error -> error
    end
  end

  defp generate_verdicts([], _truths, _opts) do
    # No claims means perfectly faithful
    {:ok, []}
  end

  defp generate_verdicts(claims, truths, opts) do
    truths_text = Enum.join(truths, "\n\n")

    prompt =
      Template.generate_verdicts(
        claims: claims,
        retrieval_context: truths_text
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # Borderline claims count as faithful, as in deepeval 4.3.1 without
  # `penalize_ambiguous_claims`
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes, :borderline],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, verdicts, true, opts) do
    contradictions =
      verdicts
      |> Enum.filter(fn %{verdict: v} -> v == :no end)
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      Template.generate_reason(
        score: score,
        contradictions: contradictions
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
