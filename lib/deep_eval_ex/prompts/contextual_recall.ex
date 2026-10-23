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
  of the same name byte for byte. Both take deepeval's `multimodal` flag
  as the `:multimodal` option (default `false`), which a multimodal
  `DeepEvalEx.TestCase` sets: they then speak of "sentences and images",
  the verdicts template adds the multimodal node instruction and shows the
  retrieval context as numbered text and image nodes
  (`DeepEvalEx.Metrics.Utils.RetrievalContextDisplay`). Lists are printed
  as Python lists and scores as
  `format(score, ".2f")` (see `DeepEvalEx.Prompts.Python`).
  `system_one_verdict/0` and `system_one_questions/0` are its System One
  templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Metrics.Utils.RetrievalContextDisplay
  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to produce verdicts for each sentence in the expected output.

  Each verdict indicates whether the sentence can be attributed to
  nodes in the retrieval context.

  ## Options

  - `:expected_output` - the test case expected output (required)
  - `:retrieval_context` - the retrieval context, a list of strings
    (required)
  - `:multimodal` - whether the test case holds images (default: `false`)
  - `:images` - the test case's images, by id, whose placeholders the
    multimodal retrieval context shows (default: none)
  """
  def generate_verdicts(opts) do
    expected_output = Keyword.fetch!(opts, :expected_output)
    contexts = Keyword.fetch!(opts, :retrieval_context)
    multimodal = Keyword.get(opts, :multimodal, false)
    pick = fn multimodal_text, text -> if multimodal, do: multimodal_text, else: text end
    content_type = pick.("sentence and image", "sentence")
    content_or = pick.("sentence or image", "sentence")

    node_instruction =
      pick.(
        " A node is either a string or image, but not both (so do not group images and texts in the same nodes).",
        ""
      )

    retrieval_context =
      if multimodal,
        do:
          contexts |> RetrievalContextDisplay.id_retrieval_context(opts[:images]) |> Python.repr(),
        else: Python.repr(contexts)

    """
    For EACH #{content_type} in the given expected output below, determine whether the #{content_or} can be attributed to the nodes of retrieval contexts. Please generate a list of JSON with two keys: `verdict` and `reason`.
    The `verdict` key should STRICTLY be either a 'yes' or 'no'. Answer 'yes' if the #{content_or} can be attributed to any parts of the retrieval context, else answer 'no'.
    The `reason` key should provide a reason why to the verdict. In the reason, you should aim to include the node(s) count in the retrieval context (eg., 1st node, and 2nd node in the retrieval context) that is attributed to said #{content_or}.#{node_instruction} You should also aim to quote the specific part of the retrieval context to justify your verdict, but keep it extremely concise and cut short the quote with an ellipsis if possible. 

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

    Since you are going to generate a verdict for each sentence, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to the number of #{pick.("sentences and images", "sentences")} in #{pick.("the `expected output`", "`expected output`")}.
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
  - `:multimodal` - whether the test case holds images (default: `false`)
  """
  def generate_reason(opts) do
    multimodal = Keyword.get(opts, :multimodal, false)
    pick = fn multimodal_text, text -> if multimodal, do: multimodal_text, else: text end
    content_type = pick.("sentence or image", "sentence")
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    expected_output = Keyword.fetch!(opts, :expected_output)
    supportive_reasons = opts |> Keyword.fetch!(:supportive_reasons) |> Python.repr()
    unsupportive_reasons = opts |> Keyword.fetch!(:unsupportive_reasons) |> Python.repr()

    """
    Given the original expected output, a list of supportive reasons, and a list of unsupportive reasons (#{pick.("which is", "which are")} deduced directly from the #{pick.(~s("expected output"), "original expected output")}), and a contextual recall score (closer to 1 the better), summarize a CONCISE reason for the score.
    A supportive reason is the reason why a certain #{content_type} in the original expected output can be attributed to the node in the retrieval context.
    An unsupportive reason is the reason why a certain #{content_type} in the original expected output cannot be attributed to anything in the retrieval context.
    In your reason, you should #{pick.("related", "relate")} supportive/unsupportive reasons to the #{content_type} number in expected output, and #{pick.("info", "include info")} regarding the node number in retrieval context to support your final reason. The first mention of "node(s)" should specify "node(s) in retrieval context#{pick.(")", "")}.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_recall_score> because <your_reason>."
    }

    DO NOT mention 'supportive reasons' and 'unsupportive reasons' in your reason, these terms are just here for you to understand the broader scope of things.
    If the score is 1, keep it short and say something positive with an upbeat encouraging tone (but don't overdo it#{pick.(",", "")} otherwise it gets annoying).
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

  @doc """
  The question a System One model is asked about each sentence of the
  expected output under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_verdict` template: a Noul whose instructions
  pair it with the sentence, about a state holding the
  `retrieval_context` (see `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict, do: "Can `sentence` be attributed to the facts in `retrieval_context`?"

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about
  `expected_output` and `retrieval_context`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every sentence in `expected_output` can be attributed to the facts in `retrieval_context`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "`retrieval_context` contains the key facts needed to write `expected_output`."
      },
      {
        "type": "score",
        "question": "How much of `expected_output` can be attributed to the facts in `retrieval_context`?",
        "levels": ["None of it", "Less than half", "Most of it", "All of it"]
      }
    ]\
    """
  end
end
