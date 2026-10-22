# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/turn_contextual_recall/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TurnContextualRecall do
  @moduledoc """
  Prompt templates for the TurnContextualRecall metric.

  TurnContextualRecall measures whether each sentence of a conversation's
  `expected_outcome` can be attributed to the retrieval context of each
  sliding window of the conversation.

  Each function renders deepeval 4.3.1's `TurnContextualRecallMetric`
  template of the same name byte for byte. The window templates leave out
  the multimodal wording and input rules (`DeepEvalEx.Prompts.Fragments`),
  keeping the blank lines around them, unless the `:multimodal` option is
  `true`, as for a multimodal `DeepEvalEx.ConversationalTestCase`. Lists
  are printed as Python lists, a window's score as `format(score, ".2f")`
  and the final score as Python's `str()` of it, unformatted, as deepeval
  passes them (see `DeepEvalEx.Prompts.Python`). `system_one_verdict/0`
  and `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_verdicts: 1,
      generate_reason: 1,
      generate_final_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.{Fragments, Python}

  @doc """
  Generates a prompt to judge whether each sentence of the expected outcome
  can be attributed to a window's retrieval context.

  ## Options

  - `:expected_outcome` - the conversation's expected outcome (required)
  - `:retrieval_context` - the retrieval context of the window's assistant
    turns, in order, printed as a Python list; under `:multimodal` each
    node is prefixed with `"Node <n>: "`, as deepeval's
    `id_retrieval_context` does a text node (required)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal wording and input rules (default: `false`)
  """
  def generate_verdicts(opts) do
    expected_outcome = Keyword.fetch!(opts, :expected_outcome)
    contexts = Keyword.fetch!(opts, :retrieval_context)
    multimodal = Keyword.get(opts, :multimodal, false)
    context_to_display = contexts |> context_to_display(multimodal) |> Python.repr()

    {content_type, content_type_plural, content_or, node_instruction, the, assistant_output} =
      if multimodal do
        {"sentence and image", "sentences and images", "sentence or image",
         " A node is either a string or image, but not both (so do not group images and " <>
           "texts in the same nodes).", "the", " `assistant output`"}
      else
        {"sentence", "sentences", "sentence", "", "`assistant output`", ""}
      end

    """
    For EACH #{content_type} in the given assistant output below, determine whether the #{content_or} can be attributed to the nodes of retrieval contexts. Please generate a list of JSON with two keys: `verdict` and `reason`.
    The `verdict` key should STRICTLY be either a 'yes' or 'no'. Answer 'yes' if the #{content_or} can be attributed to any parts of the retrieval context, else answer 'no'.
    The `reason` key should provide a reason why to the verdict. In the reason, you should aim to include the node(s) count in the retrieval context (eg., 1st node, and 2nd node in the retrieval context) that is attributed to said #{content_or}.#{node_instruction} You should also aim to quote the specific part of the retrieval context to justify your verdict, but keep it extremely concise and cut short the quote with an ellipsis if possible. 

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

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

    Since you are going to generate a verdict for each sentence, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to the number of #{content_type_plural} in #{the}#{assistant_output}.
    **

    Assistant Output:
    #{expected_outcome}

    Retrieval Context:
    #{context_to_display}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain a window's score from the reasons of its
  verdicts.

  ## Options

  - `:score` - the window's score, printed as `format(score, ".2f")`
    (required)
  - `:expected_outcome` - the conversation's expected outcome (required)
  - `:supportive_reasons` - the reasons of the `yes` verdicts (required)
  - `:unsupportive_reasons` - the reasons of the other verdicts (required)
  - `:multimodal` - as for `generate_verdicts/1`
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    expected_outcome = Keyword.fetch!(opts, :expected_outcome)
    supportive_reasons = opts |> Keyword.fetch!(:supportive_reasons) |> Python.repr()
    unsupportive_reasons = opts |> Keyword.fetch!(:unsupportive_reasons) |> Python.repr()

    {content_type, which, deduced_from, relate, include, paren, comma} =
      if Keyword.get(opts, :multimodal, false) do
        {"sentence or image", "which is", ~s("assistant output"), "related", "info", ")", ","}
      else
        {"sentence", "which are", "original assistant output", "relate", "include info", "", ""}
      end

    """
    Given the original assistant output, a list of supportive reasons, and a list of unsupportive reasons (#{which} deduced directly from the #{deduced_from}), and a contextual recall score (closer to 1 the better), summarize a CONCISE reason for the score.
    A supportive reason is the reason why a certain #{content_type} in the original assistant output can be attributed to the node in the retrieval context.
    An unsupportive reason is the reason why a certain #{content_type} in the original assistant output cannot be attributed to anything in the retrieval context.
    In your reason, you should #{relate} supportive/unsupportive reasons to the #{content_type} number in assistant output, and #{include} regarding the node number in retrieval context to support your final reason. The first mention of "node(s)" should specify "node(s) in retrieval context#{paren}.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_recall_score> because <your_reason>."
    }

    DO NOT mention 'supportive reasons' and 'unsupportive reasons' in your reason, these terms are just here for you to understand the broader scope of things.
    If the score is 1, keep it short and say something positive with an upbeat encouraging tone (but don't overdo it#{comma} otherwise it gets annoying).
    **

    Contextual Recall Score:
    #{score}

    Assistant Output:
    #{expected_outcome}

    Supportive Reasons:
    #{supportive_reasons}

    Unsupportive Reasons:
    #{unsupportive_reasons}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the final score from every window's reason.

  ## Options

  - `:final_score` - the metric's score, printed as Python's `str()`
    (required)
  - `:success` - whether the metric passed (required)
  - `:reasons` - every window's reason, in order (`nil` included)
    (required)
  """
  def generate_final_reason(opts) do
    final_score = opts |> Keyword.fetch!(:final_score) |> Python.repr()
    success = opts |> Keyword.fetch!(:success) |> Python.repr()
    reasons = opts |> Keyword.fetch!(:reasons) |> Python.repr()

    """
    You are an AI evaluator producing a single final explanation for the TurnContextualRecallMetric result.

    Context:
    This metric evaluates conversational contextual recall by determining whether sentences in the assistant output can be attributed to the retrieval context for each interaction. Each interaction yields a reason indicating which sentences were supported or unsupported. You are given all those reasons.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_recall_score> because <your_reason>."
    }

    Inputs:
    - final_score: the averaged score across all interactions.
    - success: whether the metric passed or failed
    - reasons: a list of textual reasons generated from individual interactions.

    Instructions:
    1. Read all reasons and synthesize them into one unified explanation.
    2. Describe patterns of unsupported sentences, missing context coverage, or well-attributed outputs if present.
    3. Do not repeat every reason; merge them into a concise, coherent narrative.
    4. If the metric failed, state the dominant failure modes. If it passed, state why the assistant output was well-supported by retrieval context.
    5. Output a single paragraph with no lists, no bullets, no markup.

    Output:
    A single paragraph explaining the final outcome.

    Here's the inputs:

    Final Score: #{final_score}

    Reasons: 
    #{reasons}

    Success: #{success}

    Now give me a final reason that explains why the metric passed or failed. Output ONLY the reason and nothing else.

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each sentence of the
  expected outcome under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_verdict` template: a Noul whose instructions
  pair it with the sentence, about a state holding the window's
  `retrieval_context` (see `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict, do: "Can `sentence` be attributed to the facts in `retrieval_context`?"

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about how much of the `expected_outcome` the
  `retrieval_context` of the `turns` supports, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every sentence in `expected_outcome` can be attributed to the facts in the `retrieval_context` of the assistant turns in `turns`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "The `retrieval_context` of the assistant turns in `turns` contains the key facts needed to reach `expected_outcome`."
      },
      {
        "type": "score",
        "question": "How much of `expected_outcome` can be attributed to the facts in the `retrieval_context` of the assistant turns in `turns`?",
        "levels": ["None of it", "Less than half", "Most of it", "All of it"]
      }
    ]\
    """
  end

  # deepeval's id_retrieval_context, for text nodes.
  defp context_to_display(contexts, false), do: contexts

  defp context_to_display(contexts, true) do
    for {context, n} <- Enum.with_index(contexts, 1), do: "Node #{n}: #{Python.str(context)}"
  end
end
