# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/conversation_completeness/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ConversationCompleteness do
  @moduledoc """
  Prompt templates for the ConversationCompleteness metric.

  ConversationCompleteness measures whether the assistant satisfies every
  intention the user expresses in a conversation.

  Each function renders deepeval 4.3.1's `ConversationCompletenessMetric`
  template of the same name byte for byte, as deepeval renders it for a
  text-only test case (`multimodal=False`): the multimodal input rules
  fragment is left out, keeping the blank lines around it, unless the
  `:multimodal` option is `true`, as for a multimodal
  `DeepEvalEx.ConversationalTestCase`. Turns and lists are printed as Python lists
  (see `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2`) and the
  score as Python's `str()` of it, unformatted, as deepeval passes it (see
  `DeepEvalEx.Prompts.Python`). `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      extract_user_intentions: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract the user's intentions from the
  conversation.

  ## Options

  - `:turns` - the conversation's turns as dicts, a list of
    `Jason.OrderedObject`s or maps (required)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal input rules (default: `false`)
  """
  def extract_user_intentions(opts) do
    turns = opts |> Keyword.fetch!(:turns) |> Python.repr()

    """
    Based on the given list of message exchanges between a user and an LLM, generate a JSON object to extract all user intentions in the conversation. The JSON will have 1 field: 'intentions'.
    You should ONLY consider the overall intention, and not dwell too much on the specifics, as we are more concerned about the overall objective of the conversation.

    #{multimodal_rules(opts)}

    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Turns:
    [
      {
        "role": "user",
        "content": "Hi!"
      },
      {
        "role": "assistant",
        "content": "Hello! How may I help you?"
      },
      {
        "role": "user",
        "content": "Nothing, I'm just playing with you."
      },
      {
        "role": "assistant",
        "content": "Oh ok, in that case should you need anything just let me know!"
      },
      {
        "role": "user",
        "content": "Actually, I have something I want to tell you"
      }
    ]

    Example JSON:
    {
      "intentions": ["User wants to tell the assistant something"]
    }
    ===== END OF EXAMPLE ======

    The 'intentions' key must be a list of strings.
    If there are multiple individual tasks at each turn, please give the intentions separately, DON'T summarize the intentions into a single one
    **

    Turns:
    #{turns}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to judge whether the conversation satisfies one user
  intention.

  ## Options

  - `:turns` - the conversation's turns as dicts, a list of
    `Jason.OrderedObject`s or maps (required)
  - `:intention` - the user intention to judge (required)
  - `:multimodal` - as for `extract_user_intentions/1`
  """
  def generate_verdicts(opts) do
    turns = opts |> Keyword.fetch!(:turns) |> Python.repr()
    intention = Keyword.fetch!(opts, :intention)

    """
    Based on the given list of message exchanges between a user and an LLM, generate a JSON object to indicate whether given user intention was satisfied from the conversation messages. The JSON will have 2 fields: 'verdict' and 'reason'.

    #{multimodal_rules(opts)}

    The 'verdict' key should STRICTLY be either 'yes' or 'no', which states whether the user intention was satisfied or not.
    Provide a 'reason' ONLY if the answer is 'no'.
    You MUST USE look at all messages provided in the list of messages to make an informed judgement on satisfaction.

    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Turns:
    [
      {
        "role": "user",
        "content": "Hi!"
      },
      {
        "role": "assistant",
        "content": "Hello! How may I help you?"
      },
      {
        "role": "user",
        "content": "Nothing, I'm just playing with you."
      },
      {
        "role": "assistant",
        "content": "Oh ok, in that case should you need anything just let me know!"
      },
      {
        "role": "user",
        "content": "Actually, I have something I want to tell you"
      }
    ]

    Example Intention:
    User wants to tell the assistant something.

    Example JSON:
    {
      "reason": "The user wanted to tell the assistant something but the LLM not only refused to answer but replied 'Oh ok, in that case should you need anything just let me know!', which is completely irrelevant and doesn't satisfy the user at all.",
      "verdict": "no"
    }
    ===== END OF EXAMPLE ======

    You MUST TRY to quote some LLM responses if providing a reason.
    You DON'T have to provide a reason if the answer is 'yes'.
    ONLY provide a 'no' answer if the LLM responses are failed to satisfy the user intent.
    **

    Turns:
    #{turns}

    User Intention:
    #{intention}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the completeness score from the unmet
  intentions.

  ## Options

  - `:score` - the completeness score, printed as Python's `str()`
    (required)
  - `:intentions` - the user intentions, a list of strings (required)
  - `:incompletenesses` - the reasons of the `"no"` verdicts, `nil` where
    the judge gave none (required)
  - `:multimodal` - as for `extract_user_intentions/1`
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.repr()
    intentions = opts |> Keyword.fetch!(:intentions) |> Python.repr()
    incompletenesses = opts |> Keyword.fetch!(:incompletenesses) |> Python.repr()

    """
    Below is a list of incompletenesses drawn from some messages in a conversation, which you have minimal knowledge of. It is a list of strings explaining why an LLM 'actual_output' is incomplete to satisfy the user `input` for a particular message.

    #{multimodal_rules(opts)}

    Given the completeness score, which is a 0-1 score indicating how incomplete the OVERALL `actual_output`s are to the user intentions found in the `input`s of a conversation (higher the better), CONCISELY summarize the incompletenesses to justify the score. 

    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <completeness_score> because <your_reason>."
    }

    Always quote information that are cited from messages in the incompletenesses in your final reason.
    You should NOT mention incompletenesses in your reason, and make the reason sound convincing.
    You should mention LLM response instead of `actual_output`, and User instead of `input`.
    Always refer to user intentions, but meet it minimal and phrase it in your own words. Explain which are met with supporting reason from the provided incompletenesses.
    Be sure in your reason, as if you know what the `actual_output`s from messages in a conversation is from the incompletenesses.
    **

    Completeness Score:
    #{score}

    User Intentions:
    #{intentions}

    Incompletenesses:
    #{incompletenesses}

    JSON:\
    """
  end

  # deepeval's `{% if multimodal %}{{ _fragments.multimodal_input_rules }}{% endif %}`.
  defp multimodal_rules(opts) do
    if Keyword.get(opts, :multimodal, false) do
      """

      --- MULTIMODAL INPUT RULES ---
      - Treat image content as factual evidence.
      - Only reference visual details that are explicitly and clearly visible.
      - Do not infer or guess objects, text, or details not visibly present.
      - If an image is unclear or ambiguous, mark uncertainty explicitly.
      """
    else
      ""
    end
  end

  @doc """
  The question a System One model is asked about each user intention under
  the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: one Noul about the conversation's `turns` and the `intention`
  (see `DeepEvalEx.SystemOne.Spec.Binary`). P(yes) is the probability that
  the intention is satisfied.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Do the assistant turns in `turns` satisfy `intention`? Answer no if the assistant " <>
      "ignored, refused or only partly addressed it."
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
        "statement": "Every intention the user expresses in `turns` is satisfied by the assistant turns by the end of the conversation.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No user request in `turns` is ignored, refused without cause or left only partly addressed by the assistant."
      },
      {
        "type": "score",
        "question": "Across `turns`, how many of the user's intentions does the assistant satisfy?",
        "levels": ["None satisfied", "Few satisfied", "Most satisfied", "All satisfied"]
      }
    ]\
    """
  end
end
