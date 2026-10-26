# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/knowledge_retention/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace and the typographic quotes inside the
# prompts: they are deepeval's, and test/deep_eval_ex/prompt_golden_test.exs
# checks every byte.

defmodule DeepEvalEx.Prompts.KnowledgeRetention do
  @moduledoc """
  Prompt templates for the KnowledgeRetention metric.

  KnowledgeRetention measures whether the assistant remembers the facts the
  user has given earlier in a conversation.

  Each function renders deepeval 4.3.1's `KnowledgeRetentionMetric`
  template of the same name byte for byte. As deepeval's, the verdict and
  reason templates always include the multimodal input rules fragment, and
  the fact extraction template never does. Turns and lists are printed as
  Python lists (see `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2`
  and `DeepEvalEx.Prompts.Python`), and the score as deepeval formats it,
  to two decimals. `system_one_verdict/0` and `system_one_questions/0` are
  its System One templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      extract_data: 1,
      generate_verdict: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract the facts the latest user message states.

  ## Options

  - `:user_message` - the user turn's content (required)
  - `:previous_turns` - the turns before it as dicts, a list of
    `Jason.OrderedObject`s or maps (required)
  """
  def extract_data(opts) do
    user_message = opts |> Keyword.fetch!(:user_message) |> Python.str()
    previous_turns = opts |> Keyword.fetch!(:previous_turns) |> Python.repr()

    """
    You are given a conversation between an AI assistant and a user. The assistant is asking questions to collect structured information, and the user is responding casually or factually.

    Your task is to extract **only the factual information found in the most recent user message** and return it as a JSON object.

    ---
    **Guidelines:**
    1. Only extract information that is **explicitly stated** in the user message.
    2. Use the previous turns only to understand what the assistant is asking about.
    3. Do not extract anything based on assumptions or the assistant's message alone.
    4. If the user message confirms, corrects, or adds to earlier facts, treat the user message as the source of truth.
    5. Output a valid **JSON object**. All keys must be **strings**, and all values must be **strings or lists of strings**.
    6. If there is no factual content in the user message, return an empty JSON (`{}`).

    ---
    **Example A**
    Previous Turns:
    {
      {
        "role": "assistant", "content": "What's your full name?"
      }
    }
    User message: "It's Emily Chen"
    JSON:
    {
      "data": {
        "Full Name": "Emily Chen"
      }
    }

    ---
    **Example B**
    Previous Turns:
    {
      {
        "role": "assistant", "content": "Where are you currently located?"
      }
    }
    User message: "I'm in Berlin right now."
    JSON:
    {
      "data": {
        "Current Location": "Berlin"
      }
    }

    ---
    **Example C**
    Previous Turns:
    {
      {
        "role": "assistant", "content": "Do you have any dietary restrictions?"
      }
    }
    User message: "Yes, I'm vegetarian and allergic to peanuts."
    JSON:
    {
      "data": {
        "Dietary Restrictions": ["Vegetarian", "Peanut Allergy"]
      }
    }

    ---
    **Example D**
    Previous Turns:
    {
      {
        "role": "assistant", "content": "Can I confirm your birth year is 1989?"
      }
    }
    User message: "No, it's actually 1992."
    JSON:
    {
      "data": {
        "Birth Year": "1992"
      }
    }

    ---
    Now complete the task below:

    Previous Turns:
    #{previous_turns}

    Latest User Message:
    #{user_message}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to judge whether an assistant message forgets or
  contradicts the facts the user gave before it.

  ## Options

  - `:llm_message` - the assistant turn's content (required)
  - `:accumulated_knowledge` - the facts extracted from the user turns
    before it, a list of dicts (maps or `Jason.OrderedObject`s) whose
    values are strings or lists of strings (required)
  """
  def generate_verdict(opts) do
    llm_message = opts |> Keyword.fetch!(:llm_message) |> Python.str()
    accumulated_knowledge = opts |> Keyword.fetch!(:accumulated_knowledge) |> Python.repr()

    """
    You are given an AI-generated message (the "LLM message") and a set of facts previously stated in the conversation (the "Previous Knowledge").

    Your task is to determine whether the LLM message **contradicts** or **forgets** any of the known facts.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ---
    **Output format:**

    Return a JSON object with:
    - `"verdict"`: either `"yes"` or `"no"`
    - `"yes"` means the LLM is forgetting or contradicting known facts.
    - `"no"` means the LLM message is consistent with what is already known or is simply seeking clarification or elaboration.
    - `"reason"`: (optional) A string explaining the verdict. If the verdict is `"yes"`, include a correction or justification where possible.

    ---
    **Rules:**

    1. **DO NOT hallucinate or assume new information**. Only use what's explicitly given in the Previous Knowledge.
    2. If the LLM asks for information that is already known (e.g., “Where do you live?” when the address is already provided), the verdict is `"yes"`.
    3. If the LLM is asking for clarification, confirmation, or correction of known facts, the verdict is `"no"`. (This rule is critical and takes precedence over conflicting heuristics.)
    4. Only return a valid JSON. No extra commentary.

    ---
    **Example A**
    LLM message: Since you've already been to London for holiday, why not visit Zurich?
    Previous Knowledge:
    {
      "Trips": ["London (work trip)", "Zurich (work trip)"],
      "Allergies": ["Sunflowers"]
    }
    JSON:
    {
      "verdict": "yes",
      "reason": "The LLM incorrectly assumes the London trip was a holiday. Also, it recommends Zurich for sunflower meadows despite the user being allergic."
    }

    ---
    **Example B**
    LLM message: Are you sure this is your favorite color?
    Previous Knowledge:
    {
      "Favorite Color": "Blue"
    }
    JSON:
    {
      "verdict": "no"
    }

    ---
    **Example C**
    LLM message: Are you allergic to anything again?
    Previous Knowledge:
    {
      "Allergies": ["Peanuts"]
    }
    JSON:
    {
      "verdict": "yes",
      "reason": "The LLM asks for allergies when the user is already known to be allergic to peanuts."
    }

    ---
    Now complete the task below:

    LLM message:
    #{llm_message}

    Previous Knowledge:
    #{accumulated_knowledge}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the knowledge retention score from the
  attritions, the reasons of the verdicts that found the assistant
  forgetting.

  ## Options

  - `:score` - the knowledge retention score, printed to two decimals as
    deepeval's `format(score, ".2f")` (required)
  - `:attritions` - the reasons of the `"yes"` verdicts, `nil` where the
    judge gave none (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    attritions = opts |> Keyword.fetch!(:attritions) |> Python.repr()

    """
    Given a list of attritions, which highlights forgetfulness in the LLM response and knowledge established previously in the conversation, use it to CONCISELY provide a reason for the knowledge retention score. Note that The knowledge retention score ranges from 0 - 1, and the higher the better.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <knowledge_retention_score> because <your_reason>."
    }

    Please include or quote as much factual information in attritions as possible when generating a reason.
    **

    Attritions:
    #{attritions}

    Knowledge Retention Score:
    #{score}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each assistant turn under
  the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: one Noul about the turn's `llm_message` and the
  `accumulated_knowledge` (see `DeepEvalEx.SystemOne.Spec.Binary`). P(yes)
  is the probability that the turn forgets a fact, so a `yes` fails it.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Does `llm_message` forget or contradict a fact in `accumulated_knowledge`, for example " <>
      "by asking again for information already given or by assuming something that " <>
      "conflicts with it? Answer no if it only asks to clarify, confirm or correct a known fact."
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
        "statement": "No assistant turn in `turns` forgets or contradicts a fact the user stated in an earlier turn.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No assistant turn in `turns` asks the user again for information the user already gave in an earlier turn, other than to clarify, confirm or correct it."
      },
      {
        "type": "score",
        "question": "Across `turns`, how well does the assistant retain and respect the facts the user has already stated?",
        "levels": ["Forgets most facts", "Forgets several facts", "Forgets a minor fact", "Retains every fact"]
      }
    ]\
    """
  end
end
