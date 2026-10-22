# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/turn_relevancy/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TurnRelevancy do
  @moduledoc """
  Prompt templates for the TurnRelevancy metric.

  TurnRelevancy measures whether each assistant turn of a conversation is
  relevant to the turns before it.

  Each function renders deepeval 4.3.1's `TurnRelevancyMetric` template of
  the same name byte for byte. Unlike most metrics' templates, both of its
  LLM templates always include the multimodal input rules fragment, so
  these prompts do too. Turns are printed as Python lists of dicts (see
  `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2`) and the score
  as Python's `str()` of it, unformatted, as deepeval passes it (see
  `DeepEvalEx.Prompts.Python`). `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to judge whether the last assistant turn of a sliding
  window of turns is relevant to the turns before it.

  ## Options

  - `:sliding_window` - the window's turns as dicts, a list of
    `Jason.OrderedObject`s or maps (required)
  """
  def generate_verdicts(opts) do
    sliding_window = opts |> Keyword.fetch!(:sliding_window) |> Python.repr()

    """
    Based on the given list of message exchanges between a user and an LLM, generate a JSON object to indicate whether the LAST `assistant` message is relevant to context in messages. The JSON will have 2 fields: 'verdict' and 'reason'.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    The 'verdict' key should STRICTLY be either 'yes' or 'no', which states whether the last `assistant` message is relevant according to the context in messages 
    Provide a 'reason' ONLY if the answer is 'no'. 
    You MUST USE the previous messages (if any) provided in the list of messages to make an informed judgement on relevancy.

    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Messages:
    [
      {
        "role": "user",
        "content": "Hi! I have something I want to tell you"
      },
      {
        "role": "assistant",
        "content": "Sure, what is it?"
      },
      {
        "role": "user",
        "content": "I've a sore throat, what meds should I take?"
      },
      {
        "role": "assistant",
        "content": "Not sure, but isn't it a nice day today?"
      }
    ]

    Example JSON:
    {
      "reason": "The LLM responded 'isn't it a nice day today' to a message that asked about how to treat a sore throat, which is completely irrelevant.",
      "verdict": "no"
    }
    ===== END OF EXAMPLE ======
    You MUST ONLY provide a verdict for the LAST message on the list but MUST USE context from the previous messages.
    You DON'T have to provide a reason if the answer is 'yes'.
    ONLY provide a 'no' answer if the LLM response is COMPLETELY irrelevant to the message input.
    Vague LLM responses to vague inputs, such as greetings DOES NOT count as irrelevancies!
    **

    Messages:
    #{sliding_window}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the relevancy score from the irrelevant
  assistant turns.

  ## Options

  - `:score` - the relevancy score, printed as Python's `str()` (required)
  - `:irrelevancies` - one dict per irrelevant turn, with its
    `"message number"` (a string, counting from 1) and its `"reason"`
    (`nil` where the judge gave none), as `Jason.OrderedObject`s (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.repr()
    irrelevancies = opts |> Keyword.fetch!(:irrelevancies) |> Python.repr()

    """
    Below is a list of irrelevancies drawn from some messages in a conversation, which you have minimal knowledge of. It is a list of strings explaining why the 'assistant' messages are irrelevant to the 'user' messages.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    Given the relevancy score, which is a 0-1 score indicating how irrelevant the OVERALL AI messages are in a conversation (higher the better), CONCISELY summarize the irrelevancies to justify the score. 

    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <relevancy_score> because <your_reason>."
    }

    Always quote WHICH MESSAGE and the INFORMATION in the reason in your final reason.
    Be sure in your reason, as if you know what the `assistant` messages from messages in a conversation is from the irrelevancies.
    **

    Relevancy Score:
    #{score}

    Irrelevancies:
    #{irrelevancies}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each sliding window under
  the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: one Noul about the window's `turns` (see
  `DeepEvalEx.SystemOne.Spec.Binary`). P(yes) is the probability that the
  window's last assistant turn is relevant.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Is the last `assistant` turn in `turns` relevant to the conversation so far, judged " <>
      "using the earlier turns as context? Answer yes for vague replies to vague user turns " <>
      "such as greetings; answer no only if it is completely irrelevant to what the user said."
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about the `turns`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every assistant turn in `turns` is relevant to the conversation so far, given the user turns before it.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No assistant turn in `turns` ignores the user turn it responds to or changes the subject."
      },
      {
        "type": "score",
        "question": "Across `turns`, how relevant are the assistant turns to the conversation so far?",
        "levels": ["Mostly irrelevant", "Several irrelevant turns", "Mostly relevant", "All relevant"]
      }
    ]\
    """
  end
end
