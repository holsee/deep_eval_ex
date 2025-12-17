# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/hallucination/template.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.Hallucination do
  @moduledoc """
  Prompt templates for the Hallucination metric.

  Hallucination measures whether the actual output contradicts
  the provided context. Unlike Faithfulness which extracts claims
  and truths separately, Hallucination directly compares the output
  against each context item.
  """

  @doc """
  Generates a prompt to produce verdicts for each context.

  For each context, determines whether the actual output:
  - "yes" - Agrees with the context (factual alignment)
  - "no" - Contradicts the context (hallucination)
  """
  def generate_verdicts(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)
    contexts = Keyword.fetch!(opts, :contexts)

    contexts_formatted = format_contexts(contexts)
    context_count = length(contexts)

    """
    For each context in contexts, which is a list of strings, please generate a list of JSON objects to indicate whether the given 'actual output' agrees with EACH context. The JSON will have 2 fields: 'verdict' and 'reason'.

    The 'verdict' key should STRICTLY be either 'yes' or 'no', and states whether the given text agrees with the context.
    The 'reason' is the reason for the verdict. When the answer is 'no', try to provide a correction in the reason.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects.
    Example contexts: ["Einstein won the Nobel Prize for his discovery of the photoelectric effect.", "Einstein won the Nobel Prize in 1968."]
    Example actual output: "Einstein won the Nobel Prize in 1969 for his discovery of the photoelectric effect."

    Example:
    {
        "verdicts": [
            {
                "reason": "The actual output agrees with the provided context which states that Einstein won the Nobel Prize for his discovery of the photoelectric effect.",
                "verdict": "yes"
            },
            {
                "reason": "The actual output contradicts the provided context which states that Einstein won the Nobel Prize in 1968, not 1969.",
                "verdict": "no"
            }
        ]
    }

    You should NOT incorporate any prior knowledge you have and take each context at face value. Since you are going to generate a verdict for each context, the number of 'verdicts' SHOULD BE STRICTLY EQUAL TO #{context_count}.
    You should FORGIVE cases where the actual output is lacking in detail, you should ONLY provide a 'no' answer if IT IS A CONTRADICTION.
    **

    Contexts:
    #{contexts_formatted}

    Actual Output:
    #{actual_output}

    JSON:
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.
  """
  def generate_reason(opts) do
    score = Keyword.fetch!(opts, :score)
    factual_alignments = Keyword.fetch!(opts, :factual_alignments)
    contradictions = Keyword.fetch!(opts, :contradictions)

    score_formatted = Float.round(score * 1.0, 2)
    alignments_formatted = format_list(factual_alignments)
    contradictions_formatted = format_list(contradictions)

    """
    Given a list of factual alignments and contradictions, which highlights alignment/contradictions between the `actual output` and `contexts`, use it to provide a reason for the hallucination score CONCISELY. Note that the hallucination score ranges from 0 - 1, and the lower the better.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
        "reason": "The score is <hallucination_score> because <your_reason>."
    }
    **

    Factual Alignments:
    #{alignments_formatted}

    Contradictions:
    #{contradictions_formatted}

    Hallucination Score:
    #{score_formatted}

    JSON:
    """
  end

  defp format_contexts(contexts) when is_list(contexts) do
    contexts
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {context, i} -> "#{i}. #{context}" end)
  end

  defp format_list([]), do: "(none)"

  defp format_list(items) when is_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, i} -> "#{i}. #{item}" end)
  end
end
