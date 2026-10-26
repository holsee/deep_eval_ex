# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/classifiers/classifier/templates/*.txt), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.Classifier do
  @moduledoc """
  Prompt templates for `DeepEvalEx.Classifier`, deepeval 4.3.1's
  `Classifier` templates, rendered byte for byte as deepeval's Jinja
  renders them.

  - `classify_single_turn/1` and `classify_multi_turn/1` - the `:llm` eval
    mode's prompt for a `DeepEvalEx.TestCase` and a
    `DeepEvalEx.ConversationalTestCase`
  - `system_one_classify/1` - the instructions of the one Choice the
    `:system_one` eval mode asks, deepeval's
    `_experimental_system_one_classify`

  A classifier's `:template` overrides `classify_single_turn/1` and
  `classify_multi_turn/1` (see `DeepEvalEx.Prompts.EvaluationTemplate`), as
  deepeval's `classification_template`. `system_one_classify/1` is not
  overridable: deepeval names its template class explicitly, which bypasses
  `classification_template`.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [classify_single_turn: 1, classify_multi_turn: 1]

  @doc """
  The `:llm` prompt for a single-turn test case.

  ## Options

  - `:labels` - the labels as `DeepEvalEx.Classifier.Utils.format_labels/1`
    lists them (required)
  - `:test_case_content` - the test case's populated fields, as
    `DeepEvalEx.Classifier.Utils.single_turn_content/1` prints them
    (required)
  - `:allow_none` - whether the judge may answer `"NONE"` (default: `false`)
  """
  @spec classify_single_turn(keyword()) :: String.t()
  def classify_single_turn(opts) do
    labels = Keyword.fetch!(opts, :labels)
    content = Keyword.fetch!(opts, :test_case_content)
    allow_none = Keyword.get(opts, :allow_none, false)

    "You are a classifier. Given the test case below, assign it exactly ONE label from the " <>
      "closed set of labels provided and return a JSON object with two fields:\n\n" <>
      label_field(allow_none) <>
      "- `\"reason\"`: a brief explanation for why this label was chosen. Reference specific " <>
      "details from the test case. Do **not** invent labels that are not in the list.\n\n" <>
      "Rules:\n" <>
      "- Use the label descriptions as the boundary for each label. When a description is " <>
      "given, it is authoritative.\n" <>
      "- Choose exactly one label. Never return multiple labels.\n" <>
      closing_rules(allow_none) <>
      "---\n\nLabels:\n#{labels}\n\nTest Case:\n#{content}\n\n" <>
      example(allow_none)
  end

  @doc """
  The `:llm` prompt for a conversational test case.

  ## Options

  - `:labels` - as for `classify_single_turn/1` (required)
  - `:turns` - the turns as Python prints a list of dicts, as
    `DeepEvalEx.Classifier.Utils.turns/1` builds them (required)
  - `:test_case_content` - the conversation's populated fields, as
    `DeepEvalEx.Classifier.Utils.multi_turn_content/1` prints them; left out
    with the blank line around it when empty (default: `""`)
  - `:allow_none` - whether the judge may answer `"NONE"` (default: `false`)
  """
  @spec classify_multi_turn(keyword()) :: String.t()
  def classify_multi_turn(opts) do
    labels = Keyword.fetch!(opts, :labels)
    turns = Keyword.fetch!(opts, :turns)
    content = Keyword.get(opts, :test_case_content, "")
    allow_none = Keyword.get(opts, :allow_none, false)

    content = if content in [nil, ""], do: "", else: "\n#{content}\n"

    "You are a classifier. Given the conversation below, assign it exactly ONE label from the " <>
      "closed set of labels provided and return a JSON object with two fields:\n\n" <>
      label_field(allow_none) <>
      "- `\"reason\"`: a brief explanation for why this label was chosen. Reference specific " <>
      "turns or details from the conversation. Do **not** invent labels that are not in the " <>
      "list.\n\n" <>
      "Rules:\n" <>
      "- Use the label descriptions as the boundary for each label. When a description is " <>
      "given, it is authoritative.\n" <>
      "- Consider the conversation as a whole, not just the last turn, unless a label " <>
      "description says otherwise.\n" <>
      "- Choose exactly one label. Never return multiple labels.\n" <>
      closing_rules(allow_none) <>
      "---\n\nLabels:\n#{labels}\n#{content}\nTurns:\n#{turns}\n\n" <>
      example(allow_none)
  end

  @doc """
  The instructions of the `:system_one` Choice over the labels.

  ## Options

  - `:allow_none` - whether `NONE` is one of the options (default: `false`)
  - `:multi_turn` - whether the state is a conversation (default: `false`)

  ## Examples

      iex> DeepEvalEx.Prompts.Classifier.system_one_classify(allow_none: true)
      "Which option best describes `test_case`? Each option is a label; where a description is given it is the authoritative boundary for that label. Pick `NONE` only when no other label fits."
  """
  @spec system_one_classify(keyword()) :: String.t()
  def system_one_classify(opts) do
    multi_turn = Keyword.get(opts, :multi_turn, false)

    subject = if multi_turn, do: "the conversation in `turns`", else: "`test_case`"

    whole =
      if multi_turn,
        do:
          " Consider the conversation as a whole, not just the last turn, unless a label " <>
            "description says otherwise.",
        else: ""

    pick =
      if Keyword.get(opts, :allow_none, false),
        do: " Pick `NONE` only when no other label fits.",
        else: " Pick the closest label even when the fit is imperfect."

    "Which option best describes #{subject}? Each option is a label; where a description is " <>
      "given it is the authoritative boundary for that label." <> whole <> pick
  end

  defp label_field(allow_none) do
    none = if allow_none, do: " If none of the labels apply, return `\"NONE\"`.", else: ""

    "- `\"label\"`: the name of the single best-fitting label, copied exactly as written in " <>
      "the list of labels.#{none}\n"
  end

  defp closing_rules(true) do
    "- Only return `\"NONE\"` when no label fits; do not use it to avoid a hard decision.\n" <>
      only_json()
  end

  defp closing_rules(false) do
    "- You must choose one of the listed labels, even when the fit is imperfect. Pick the " <>
      "closest one and explain the reservation in the reason.\n" <> only_json()
  end

  defp only_json,
    do: "- Only return valid JSON. Do **not** include any extra commentary or text.\n\n"

  defp example(allow_none) do
    none = if allow_none, do: ", or NONE", else: ""

    ~s(---\n**Example JSON:**\n{\n  "label": "one of the label names above#{none}",\n) <>
      ~s(  "reason": "your concise and informative reason here"\n}\n\nJSON:)
  end
end
