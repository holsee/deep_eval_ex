# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/contextual_recall/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ContextualRecall do
  @moduledoc """
  Prompt templates for the ContextualRecall metric.

  ContextualRecall measures whether sentences in the expected output
  can be attributed to the retrieval context.

  Each function renders deepeval 4.3.1's `ContextualRecallMetric` template
  of the same name byte for byte, as deepeval renders it for a text-only
  test case (`multimodal=False`): sentences rather than "sentences and
  images", and no multimodal node instruction, as DeepEvalEx has no
  multimodal test cases. Lists are printed as Python lists and scores as
  `format(score, ".2f")` (see `DeepEvalEx.Prompts.Python`).
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to produce verdicts for each sentence in the expected output.

  Each verdict indicates whether the sentence can be attributed to
  nodes in the retrieval context.

  ## Options

  - `:expected_output` - the test case expected output (required)
  - `:retrieval_context` - the retrieval context, a list of strings
    (required)
  """
  def generate_verdicts(opts) do
    expected_output = Keyword.fetch!(opts, :expected_output)
    retrieval_context = opts |> Keyword.fetch!(:retrieval_context) |> Python.repr()

    """
    For EACH sentence in the given expected output below, determine whether the sentence can be attributed to the nodes of retrieval contexts. Please generate a list of JSON with two keys: `verdict` and `reason`.
    The `verdict` key should STRICTLY be either a 'yes' or 'no'. Answer 'yes' if the sentence can be attributed to any parts of the retrieval context, else answer 'no'.
    The `reason` key should provide a reason why to the verdict. In the reason, you should aim to include the node(s) count in the retrieval context (eg., 1st node, and 2nd node in the retrieval context) that is attributed to said sentence. You should also aim to quote the specific part of the retrieval context to justify your verdict, but keep it extremely concise and cut short the quote with an ellipsis if possible. 

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects, each with two keys: `verdict` and `reason`.

    {
      "verdicts": [
        {
          "reason": "...",
          "verdict": "yes"
        },
        ...
      ]  
    }

    Since you are going to generate a verdict for each sentence, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to the number of sentences in `expected output`.
    **

    Expected Output:
    #{expected_output}

    Retrieval Context:
    #{retrieval_context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the contextual recall score (required)
  - `:expected_output` - the test case expected output (required)
  - `:supportive_reasons` - the reasons of the `"yes"` verdicts (required)
  - `:unsupportive_reasons` - the reasons of the `"no"` verdicts (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    expected_output = Keyword.fetch!(opts, :expected_output)
    supportive_reasons = opts |> Keyword.fetch!(:supportive_reasons) |> Python.repr()
    unsupportive_reasons = opts |> Keyword.fetch!(:unsupportive_reasons) |> Python.repr()

    """
    Given the original expected output, a list of supportive reasons, and a list of unsupportive reasons (which are deduced directly from the original expected output), and a contextual recall score (closer to 1 the better), summarize a CONCISE reason for the score.
    A supportive reason is the reason why a certain sentence in the original expected output can be attributed to the node in the retrieval context.
    An unsupportive reason is the reason why a certain sentence in the original expected output cannot be attributed to anything in the retrieval context.
    In your reason, you should relate supportive/unsupportive reasons to the sentence number in expected output, and include info regarding the node number in retrieval context to support your final reason. The first mention of "node(s)" should specify "node(s) in retrieval context.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_recall_score> because <your_reason>."
    }

    DO NOT mention 'supportive reasons' and 'unsupportive reasons' in your reason, these terms are just here for you to understand the broader scope of things.
    If the score is 1, keep it short and say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).
    **

    Contextual Recall Score:
    #{score}

    Expected Output:
    #{expected_output}

    Supportive Reasons:
    #{supportive_reasons}

    Unsupportive Reasons:
    #{unsupportive_reasons}

    JSON:\
    """
  end
end
