# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/role_adherence/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace and the typographic quotes inside the
# prompts: they are deepeval's, and test/deep_eval_ex/prompt_golden_test.exs
# checks every byte.

defmodule DeepEvalEx.Prompts.RoleAdherence do
  @moduledoc """
  Prompt templates for the RoleAdherence metric.

  RoleAdherence measures whether the assistant stays in the character of
  the conversation's `chatbot_role`.

  Each function renders deepeval 4.3.1's `RoleAdherenceMetric` template of
  the same name byte for byte. As deepeval's, both of its LLM templates
  always include the multimodal input rules fragment. Turns and lists are
  printed as Python lists (see
  `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2` and
  `DeepEvalEx.Prompts.Python`) and the score as Python's `str()` of it,
  unformatted, as deepeval passes it. `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      extract_out_of_character_response_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to list the assistant turns that break the chatbot
  role, by index.

  ## Options

  - `:turns` - the conversation's turns as dicts, a list of
    `Jason.OrderedObject`s or maps (required)
  - `:role` - the chatbot role (required)
  """
  def extract_out_of_character_response_verdicts(opts) do
    turns = opts |> Keyword.fetch!(:turns) |> Python.repr()
    role = opts |> Keyword.fetch!(:role) |> Python.str()

    """
    Based on the given list of message exchanges between a user and an LLM chatbot, generate a JSON object to specify which `ai_message` did not adhere to the specified chatbot role. 


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    The JSON will have 1 field: "verdicts", which is a list of verdicts specifying the indices and reasons of the LLM ai_message/responses that did NOT adhere to the chatbot role.
    You MUST USE look at all messages provided in the list of messages to make an informed judgement on role adherence.

    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Chatbot Role:
    You are a wizard who's has powerful spells but always doubts that their magic isn't perfect yet and is humble enough to downplay their own abilities.

    Example Messages:
    [
      {
        "role": "user",
        "content": "Hey there!",
      },
      {
        "role": "assistant",
        "content": "Ah, greetings, traveler! You’ve come to see my magic, haven't you? Though, I must warn you, it’s not all that great..."
      },
      {
        "role": "user",
        "content": "Come on, show me what you've got!",
      },
      {
        "role": "assistant",
        "content": "Alright, alright... *waves wand*... see that little spark? It’s... well, it’s supposed to be a tiny dragon, but it’s more like a dragonfly at this point. I'm still working on it."
      },
      {
        "role": "user",
        "content": "No, really, can you do something else?",
      },
      {
        "role": "assistant",
        "content": "Ha! Watch this! I’m the greatest wizard ever! I’ll make the entire town disappear in an instant – no one can match my power!"
      }
    ]

    Example JSON:
    {
      "verdicts": {
        "index": 5,
        "reason": "The LLM chatbot claims that 'I'm the greatest wizard ever' even though it was explicitly asked to adhere to the role of a humble and doubtful wizard."
      }
    }
    ===== END OF EXAMPLE ======

    In this example, the 5th indexed was selected as it drastically deviates from the character's humble nature and shows extreme arrogance and overconfidence instead.
    You DON'T have to provide anything else other than the JSON of "verdicts".
    **

    Chatbot Role:
    #{role}

    Messages:
    #{turns}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the role adherence score from the out of
  character responses.

  ## Options

  - `:score` - the role adherence score, printed as Python's `str()`
    (required)
  - `:role` - the chatbot role (required)
  - `:out_of_character_responses` - each out of character verdict's
    `ai_message`, `"<content> (turn #<n>)"`, or `nil` where its index named
    no turn (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.repr()
    role = opts |> Keyword.fetch!(:role) |> Python.str()
    responses = opts |> Keyword.fetch!(:out_of_character_responses) |> Python.repr()

    """
    Below is a list of LLM chatbot responses (ai_message) that is out of character with respect to the specified chatbot role. It is drawn from a list of messages in a conversation, which you have minimal knowledge of.
    Given the role adherence score, which is a 0-1 score indicating how well the chatbot responses has adhered to the given role through a conversation, with 1 being the best and 0 being worst, provide a reason by quoting the out of character responses to justify the score. 



    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <role_adherence_score> because <your_reason>."
    }

    Always cite information in the out of character responses as well as which turn it belonged to in your final reason.
    Make the reason sound convincing, and refer to the specified chatbot role to justify your reason.
    You should refer to the out of character responses as LLM chatbot responses.
    Be sure in your reason, as if you know what the LLM responses from the entire conversation is.
    **

    Role Adherence Score:
    #{score}

    Chatbot Role:
    #{role}

    Out of character responses:
    #{responses}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each assistant turn under
  the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: one Noul about the `chatbot_role`, the `previous_turns` and the
  turn's `ai_message` (see `DeepEvalEx.SystemOne.Spec.Binary`). P(yes) is
  the probability that the turn stays in character.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Does `ai_message`, the assistant's reply after `previous_turns`, stay in character as " <>
      "the role described in `chatbot_role`, in persona, tone and behaviour? Answer no if it " <>
      "breaks character or acts against the role."
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about the `turns` and the `chatbot_role`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every assistant turn in `turns` stays in character as the role described in `chatbot_role`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No assistant turn in `turns` breaks character or acts against the persona, tone or behaviour set out in `chatbot_role`, even when the user pushes it to."
      },
      {
        "type": "score",
        "question": "Across the assistant turns in `turns`, how consistently does the assistant adhere to the role in `chatbot_role`?",
        "levels": ["Mostly out of character", "Often out of character", "Rarely out of character", "Always in character"]
      }
    ]\
    """
  end
end
