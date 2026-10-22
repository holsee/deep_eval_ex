# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/contextual_precision/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ContextualPrecision do
  @moduledoc """
  Prompt templates for the ContextualPrecision metric.

  ContextualPrecision measures how well the retrieval system ranks
  relevant context nodes higher than irrelevant ones.

  Each function renders deepeval 4.3.1's `ContextualPrecisionMetric`
  template of the same name byte for byte, as deepeval renders it for a
  text-only test case (`multimodal=False`): the multimodal wording and note
  are left out, as DeepEvalEx has no multimodal test cases. Lists are
  printed as Python lists and scores as `format(score, ".2f")` (see
  `DeepEvalEx.Prompts.Python`).
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to produce verdicts for each retrieval context node.

  Each verdict indicates whether the context node was useful in
  arriving at the expected output.

  ## Options

  - `:input` - the test case input (required)
  - `:expected_output` - the test case expected output (required)
  - `:retrieval_context` - the retrieval context, a list of strings
    (required)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    expected_output = Keyword.fetch!(opts, :expected_output)
    contexts = Keyword.fetch!(opts, :retrieval_context)
    retrieval_context = Python.repr(contexts)
    document_count = document_count(length(contexts))

    """
    Given the input, expected output, and retrieval context, please generate a list of JSON objects to determine whether each node in the retrieval context was remotely useful in arriving at the expected output.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON. These JSON only contain the `verdict` key that outputs only 'yes' or 'no', and a `reason` key to justify the verdict. In your reason, you should aim to quote parts of the context .
    Example Retrieval Context: ["Einstein won the Nobel Prize for his discovery of the photoelectric effect", "He won the Nobel Prize in 1968.", "There was a cat."]
    Example Input: "Who won the Nobel Prize in 1968 and for what?"
    Example Expected Output: "Einstein won the Nobel Prize in 1968 for his discovery of the photoelectric effect."

    Example:
    {
      "verdicts": [
        {
          "reason": "It clearly addresses the question by stating that 'Einstein won the Nobel Prize for his discovery of the photoelectric effect.'",
          "verdict": "yes"
        },
        {
          "reason": "The text verifies that the prize was indeed won in 1968.",
          "verdict": "yes"
        },
        {
          "reason": "'There was a cat' is not at all relevant to the topic of winning a Nobel Prize.",
          "verdict": "no"
        }
      ]  
    }
    Since you are going to generate a verdict for each context, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to that of the contexts.
    **

    Input:
    #{input}

    Expected output:
    #{expected_output}

    Retrieval Context #{document_count}:
    #{retrieval_context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the contextual precision score (required)
  - `:input` - the test case input (required)
  - `:verdicts` - the node verdicts in ranking order, maps with `:verdict`
    and `:reason` (required). A verdict atom (`:yes`) prints as deepeval's
    `Verdict` enum member (`<Verdict.YES: 'yes'>`), as the verdicts of
    deepeval's metric do; a string prints as a string (`'yes'`)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    input = Keyword.fetch!(opts, :input)
    verdicts = opts |> Keyword.fetch!(:verdicts) |> Enum.map(&verdict_dict/1) |> Python.repr()

    """
    Given the input, retrieval contexts, and contextual precision score, provide a CONCISE summary for the score. Explain why it is not higher, but also why it is at its current score.
    The retrieval contexts is a list of JSON with three keys: `verdict`, `reason` (reason for the verdict) and `node`. `verdict` will be either 'yes' or 'no', which represents whether the corresponding 'node' in the retrieval context is relevant to the input. 
    Contextual precision represents if the relevant nodes are ranked higher than irrelevant nodes. Also note that retrieval contexts is given IN THE ORDER OF THEIR RANKINGS.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_precision_score> because <your_reason>."
    }


    DO NOT mention 'verdict' in your reason, but instead phrase it as irrelevant nodes. The term 'verdict' is just here for you to understand the broader scope of things.
    Also DO NOT mention there are `reason` fields in the retrieval contexts you are presented with, instead just use the information in the `reason` field.
    In your reason, you MUST USE the `reason`, QUOTES in the 'reason', and the node RANK (starting from 1, eg. first node) to explain why the 'no' verdicts should be ranked lower than the 'yes' verdicts.
    When addressing nodes, make it explicit that they are nodes in retrieval contexts.
    If the score is 1, keep it short and say something positive with an upbeat tone (but don't overdo it otherwise it gets annoying).
    **

    Contextual Precision Score:
    #{score}

    Input:
    #{input}

    Retrieval Contexts:
    #{verdicts}

    JSON:\
    """
  end

  # The document_count_str of deepeval's _contextual_precision_verdict_fields.
  defp document_count(count) when count > 1, do: " (#{count} documents)"
  defp document_count(count), do: " (#{count} document)"

  # deepeval passes each verdict as {"verdict": ..., "reason": ...}.
  defp verdict_dict(%{verdict: verdict, reason: reason}) do
    %Jason.OrderedObject{values: [{"verdict", verdict_value(verdict)}, {"reason", reason}]}
  end

  defp verdict_value(verdict) when is_atom(verdict) do
    value = Atom.to_string(verdict)
    %Python.EnumMember{class: "Verdict", name: String.upcase(value), value: value}
  end

  defp verdict_value(verdict), do: verdict
end
