# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/turn_contextual_relevancy/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TurnContextualRelevancy do
  @moduledoc """
  Prompt templates for the TurnContextualRelevancy metric.

  TurnContextualRelevancy measures whether the statements of the retrieval
  context of each sliding window of a conversation are relevant to the
  window's user turns.

  Each function renders deepeval 4.3.1's `TurnContextualRelevancyMetric`
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
  Generates a prompt to judge whether each statement of one retrieval
  context node is relevant to a window's user turns.

  ## Options

  - `:input` - the window's user turns, each as `"\\n<content> "` (required)
  - `:context` - the node (required)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal wording and input rules (default: `false`)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    context = opts |> Keyword.fetch!(:context) |> Python.str()

    {context_type, each_statement, statement_or_image, extraction_instructions,
     empty_context_instruction} =
      if Keyword.get(opts, :multimodal, false) do
        {"context (image or string)", "the context", "statement or image",
         "If the context is textual, you should first extract the statements found in the " <>
           "context if the context, which are high level information found in the context, " <>
           "before deciding on a verdict and optionally a reason for each statement.\n" <>
           "If the context is an image, `statement` should be a description of the image. " <>
           "Do not assume any information not visibly available.", ""}
      else
        {"context", "each statement found in the context", "statement",
         "You should first extract statements found in the context, which are high level " <>
           "information found in the context, before deciding on a verdict and optionally a " <>
           "reason for each statement.",
         ~s(\nIf provided context contains no actual content or statements then: give "no" ) <>
           ~s(as a "verdict",\nput context into "statement", and "No statements found in ) <>
           ~s(provided context." into "reason".)}
      end

    """
    Based on the user message and #{context_type}, please generate a JSON object to indicate whether #{each_statement} is relevant to the provided user message. The JSON will be a list of 'verdicts', with 2 mandatory fields: 'verdict' and 'statement', and 1 optional field: 'reason'.
    #{extraction_instructions}
    The 'verdict' key should STRICTLY be either 'yes' or 'no', and states whether the #{statement_or_image} is relevant to the user message.
    Provide a 'reason' ONLY IF verdict is no. You MUST quote the irrelevant parts of the #{statement_or_image} to back up your reason.#{empty_context_instruction}

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Context: "Einstein won the Nobel Prize for his discovery of the photoelectric effect. He won the Nobel Prize in 1968. There was a cat."
    Example User Message: "What were some of Einstein's achievements?"

    Example:
    {
      "verdicts": [
        {
          "statement": "Einstein won the Nobel Prize for his discovery of the photoelectric effect in 1968",
          "verdict": "yes"
        },
        {
          "statement": "There was a cat.",
          "reason": "The retrieval context contained the information 'There was a cat' when it has nothing to do with Einstein's achievements.",
          "verdict": "no"
        }
      ]
    }
    **

    User Message:
    #{input}

    Context:
    #{context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain a window's score from its statements.

  ## Options

  - `:score` - the window's score, printed as `format(score, ".2f")`
    (required)
  - `:input` - the window's user turns, as for `generate_verdicts/1`
    (required)
  - `:irrelevant_statements` - each irrelevant statement as
    `"<statement>: <reason>"` (required)
  - `:relevant_statements` - the relevant statements (required)
  - `:multimodal` - as for `generate_verdicts/1`
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    input = Keyword.fetch!(opts, :input)
    irrelevant_statements = opts |> Keyword.fetch!(:irrelevant_statements) |> Python.repr()
    relevant_statements = opts |> Keyword.fetch!(:relevant_statements) |> Python.repr()

    """
    Based on the given user message, reasons for why the retrieval context is irrelevant to the user message, the statements in the retrieval context that is actually relevant to the retrieval context, and the contextual relevancy score (the closer to 1 the better), please generate a CONCISE reason for the score.
    In your reason, you should quote data provided in the reasons for irrelevancy and relevant statements to support your point.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_relevancy_score> because <your_reason>."
    }

    If the score is 1, keep it short and say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).
    **

    Contextual Relevancy Score:
    #{score}

    User Message:
    #{input}

    Reasons for why the retrieval context is irrelevant to the user message:
    #{irrelevant_statements}

    Statement in the retrieval context that is relevant to the user message:
    #{relevant_statements}

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
    You are an AI evaluator producing a single final explanation for the TurnContextualRelevancyMetric result.

    Context:
    This metric evaluates conversational contextual relevancy by determining whether statements in the retrieval context are relevant to the user message for each interaction. Each interaction yields a reason indicating which statements were relevant or irrelevant. You are given all those reasons.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_relevancy_score> because <your_reason>."
    }

    Inputs:
    - final_score: the averaged score across all interactions.
    - success: whether the metric passed or failed
    - reasons: a list of textual reasons generated from individual interactions.

    Instructions:
    1. Read all reasons and synthesize them into one unified explanation.
    2. Describe patterns of irrelevant statements, off-topic context, or well-targeted retrieval if present.
    3. Do not repeat every reason; merge them into a concise, coherent narrative.
    4. If the metric failed, state the dominant failure modes. If it passed, state why the retrieval context was relevant to user messages.
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
  The question a System One model is asked about each sentence of a
  retrieval context node under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_verdict` template: a Noul whose instructions
  pair it with the sentence, about a state holding the window's
  `user_message` (see `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict, do: "Is `statement` relevant to addressing `user_message`?"

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about how relevant the `retrieval_context` of the
  `turns` is to the user turns before it, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every statement in the `retrieval_context` of each assistant turn in `turns` is relevant to addressing the user turns before it.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "Every node in the `retrieval_context` of each assistant turn in `turns` contains at least one statement relevant to addressing the user turns before it."
      },
      {
        "type": "score",
        "question": "Across `turns`, how much of the `retrieval_context` of the assistant turns is relevant to addressing the user turns before it?",
        "levels": ["None of it", "Less than half", "Most of it", "All of it"]
      }
    ]\
    """
  end
end
