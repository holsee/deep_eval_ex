# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/turn_contextual_precision/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TurnContextualPrecision do
  @moduledoc """
  Prompt templates for the TurnContextualPrecision metric.

  TurnContextualPrecision measures whether the retrieval context of each
  sliding window of a conversation ranks the nodes useful for reaching the
  conversation's `expected_outcome` above the others.

  Each function renders deepeval 4.3.1's `TurnContextualPrecisionMetric`
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
  Generates a prompt to judge whether each node of a window's retrieval
  context was useful in arriving at the expected outcome.

  ## Options

  - `:input` - the window's user turns, each as `"\\n<content> "` (required)
  - `:expected_outcome` - the conversation's expected outcome (required)
  - `:retrieval_context` - the retrieval context of the window's assistant
    turns, in order, printed as a Python list; under `:multimodal` each
    node is prefixed with `"Node <n>: "`, as deepeval's
    `id_retrieval_context` does a text node (required)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal note and input rules (default: `false`)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    expected_outcome = Keyword.fetch!(opts, :expected_outcome)
    contexts = Keyword.fetch!(opts, :retrieval_context)
    multimodal = Keyword.get(opts, :multimodal, false)
    document_count = document_count(length(contexts))
    context_to_display = contexts |> context_to_display(multimodal) |> Python.repr()
    multimodal_note = if multimodal, do: " (which can be text or an image)", else: ""

    """
    Given the user message, assistant output, and retrieval context, please generate a list of JSON objects to determine whether each node in the retrieval context was remotely useful in arriving at the assistant output.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON. These JSON only contain the `verdict` key that outputs only 'yes' or 'no', and a `reason` key to justify the verdict. In your reason, you should aim to quote parts of the context #{multimodal_note}.
    Example Retrieval Context: ["Einstein won the Nobel Prize for his discovery of the photoelectric effect", "He won the Nobel Prize in 1968.", "There was a cat."]
    Example User Message: "Who won the Nobel Prize in 1968 and for what?"
    Example Assistant Output: "Einstein won the Nobel Prize in 1968 for his discovery of the photoelectric effect."

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

    User Message:
    #{input}

    Assistant Output:
    #{expected_outcome}

    Retrieval Context #{document_count}:
    #{context_to_display}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain a window's score from its node verdicts.

  ## Options

  - `:score` - the window's score, printed as `format(score, ".2f")`
    (required)
  - `:input` - the window's user turns, as for `generate_verdicts/1`
    (required)
  - `:verdicts` - the node verdicts in ranking order, maps with `:verdict`
    and `:reason`, printed with their `"Node <n>"` rank. A verdict atom
    (`:yes`) prints as deepeval's `Verdict` enum member
    (`<Verdict.YES: 'yes'>`), as the verdicts of deepeval's metric do
    (required)
  - `:multimodal` - as for `generate_verdicts/1`
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    input = Keyword.fetch!(opts, :input)

    verdicts =
      opts
      |> Keyword.fetch!(:verdicts)
      |> Enum.with_index(1)
      |> Enum.map(&verdict_dict/1)
      |> Python.repr()

    multimodal = Keyword.get(opts, :multimodal, false)

    {summary, verdict_is, they_are, contexts, comma} =
      if multimodal,
        do: {"summarize", "are", "it is", "retrieval context", ","},
        else: {"summary", "is", "they are", "retrieval contexts", ""}

    """
    Given the user message, retrieval contexts, and contextual precision score, provide a CONCISE #{summary} for the score. Explain why it is not higher, but also why it is at its current score.
    The retrieval contexts is a list of JSON with three keys: `verdict`, `reason` (reason for the verdict) and `node`. `verdict` will be either 'yes' or 'no', which represents whether the corresponding 'node' in the retrieval context is relevant to the user message. 
    Contextual precision represents if the relevant nodes are ranked higher than irrelevant nodes. Also note that retrieval contexts is given IN THE ORDER OF THEIR RANKINGS.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_precision_score> because <your_reason>."
    }


    DO NOT mention 'verdict' in your reason, but instead phrase it as irrelevant nodes. The term 'verdict' #{verdict_is} just here for you to understand the broader scope of things.
    Also DO NOT mention there are `reason` fields in the retrieval contexts you are presented with, instead just use the information in the `reason` field.
    In your reason, you MUST USE the `reason`, QUOTES in the 'reason', and the node RANK (starting from 1, eg. first node) to explain why the 'no' verdicts should be ranked lower than the 'yes' verdicts.
    When addressing nodes, make it explicit that #{they_are} nodes in #{contexts}.
    If the score is 1, keep it short and say something positive with an upbeat tone (but don't overdo it#{comma} otherwise it gets annoying).
    **

    Contextual Precision Score:
    #{score}

    User Message:
    #{input}

    Retrieval Contexts:
    #{verdicts}

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
    You are an AI evaluator producing a single final explanation for the TurnContextualPrecisionMetric result.

    Context:
    This metric evaluates conversational contextual precision by determining whether relevant nodes in retrieval context are ranked higher than irrelevant nodes for each interaction. Each interaction yields a reason indicating why relevant nodes were well-ranked or poorly-ranked. You are given all those reasons.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_precision_score> because <your_reason>."
    }

    Inputs:
    - final_score: the averaged score across all interactions.
    - success: whether the metric passed or failed
    - reasons: a list of textual reasons generated from individual interactions.

    Instructions:
    1. Read all reasons and synthesize them into one unified explanation.
    2. Describe patterns of ranking issues, irrelevant nodes appearing before relevant ones, or well-structured retrieval contexts if present.
    3. Do not repeat every reason; merge them into a concise, coherent narrative.
    4. If the metric failed, state the dominant failure modes. If it passed, state why the retrieval context ranking was effective.
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
  The question a System One model is asked about each node of a window's
  retrieval context under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_verdict` template: a Noul whose instructions
  pair it with the node, about a state holding the window's
  `user_message` and the `assistant_output`, the conversation's expected
  outcome (see `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Was the retrieval context `node` remotely useful in arriving at `assistant_output` for " <>
      "`user_message`?"
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about how the `retrieval_context` of the `turns`
  is ordered towards the `expected_outcome`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "In every assistant turn in `turns` that has a `retrieval_context`, the documents useful for answering the preceding user message towards `expected_outcome` are listed before the documents that are not useful.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "In every assistant turn in `turns` that has a `retrieval_context`, the first document is useful for answering the preceding user message."
      },
      {
        "type": "score",
        "question": "Across the assistant turns in `turns`, how well are the `retrieval_context` documents ordered, with the ones useful for answering the preceding user message first?",
        "levels": ["Useful documents are all at the end", "Useful documents are mixed with irrelevant ones", "Useful documents are mostly first", "Useful documents are all first"]
      }
    ]\
    """
  end

  # The document_count_str of deepeval's _contextual_precision_verdict_fields.
  defp document_count(count) when count > 1, do: " (#{count} documents)"
  defp document_count(count), do: " (#{count} document)"

  # deepeval's id_retrieval_context, for text nodes.
  defp context_to_display(contexts, false), do: contexts

  defp context_to_display(contexts, true) do
    for {context, n} <- Enum.with_index(contexts, 1), do: "Node #{n}: #{Python.str(context)}"
  end

  # deepeval passes each verdict as {"verdict": ..., "reason": ..., "node": "Node <n>"}.
  defp verdict_dict({%{verdict: verdict, reason: reason}, n}) do
    Jason.OrderedObject.new([
      {"verdict", verdict_value(verdict)},
      {"reason", reason},
      {"node", "Node #{n}"}
    ])
  end

  defp verdict_value(verdict) when is_atom(verdict) do
    value = Atom.to_string(verdict)
    %Python.EnumMember{class: "Verdict", name: String.upcase(value), value: value}
  end

  defp verdict_value(verdict), do: verdict
end
