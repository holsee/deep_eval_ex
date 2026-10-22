# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/hallucination/hallucination.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Hallucination do
  @moduledoc """
  Hallucination metric for detecting unsupported statements.

  Measures how well the actual output aligns with the provided context.
  Unlike Faithfulness which extracts claims and truths separately,
  Hallucination directly compares the output against each context item.

  ## How It Works

  1. **Generate verdicts** - For each context, determine if the output:
     - `yes` - Agrees with the context (factual alignment)
     - `no` - Contradicts the context (hallucination)
     Other verdicts are dropped.
  2. **Calculate score** - (aligned contexts) / (total verdicts), or `1`
     when the judge returns no verdicts
  3. **Higher score is better** - Success when score ≥ threshold

  > #### Score direction {: .warning}
  >
  > Like deepeval 4.3.1, the score is the fraction of contexts the output
  > agrees with: 1.0 means no hallucination. Earlier releases scored the
  > fraction it contradicted and passed when `score <= threshold`; a
  > threshold of 0.2 that meant "at most 20% contradicted" is now 0.8. The
  > first measurement on a node logs a warning saying so, as deepeval does.

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
  result.score   # => 0.5 (1 aligned context out of 2)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.ScoreDirection,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.Hallucination, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Hallucination, as: Schema

  @impl true
  def metric_name, do: "Hallucination"

  @impl true
  def required_params, do: [:input, :actual_output, :context]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  Measures how well the actual output aligns with its context.

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    ScoreDirection.warn_flipped(metric_name())

    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    contexts = test_case.context
    actual_output = test_case.actual_output

    with {:ok, verdicts} <- generate_verdicts(actual_output, contexts, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Verdicts:\n#{verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()}",
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
           context_count: length(contexts)
         }
       )}
    end
  end

  defp generate_verdicts(_actual_output, [], _opts) do
    # No contexts means nothing to contradict
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

  # deepeval 4.3.1 scores the verdicts that pass (`yes`, the output agrees
  # with the context) over all verdicts, and an empty list as the integer 1
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
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
