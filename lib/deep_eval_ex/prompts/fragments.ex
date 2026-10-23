# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/templates/metrics/fragments/*.txt), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.Fragments do
  @moduledoc """
  Prompt fragments shared by several metrics' templates, deepeval 4.3.1's
  `_fragments`.
  """

  @doc """
  deepeval's `{% if multimodal %}{{ _fragments.multimodal_input_rules }}{% endif %}`,
  the multimodal input rules of the single-turn metrics' templates: the
  rules, between a leading and a trailing newline, when the `:multimodal`
  option is `true`, else an empty string, so the blank lines around the
  fragment stay.

  ## Examples

      iex> DeepEvalEx.Prompts.Fragments.multimodal_input_rules([])
      ""
  """
  @spec multimodal_input_rules(keyword()) :: String.t()
  def multimodal_input_rules(opts) do
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
  deepeval's `{% if multimodal %}{{ _fragments.faithfulness_verdicts_example_multimodal }}{% endif %}`
  in FaithfulnessMetric's verdicts template: the multimodal example,
  between a leading and a trailing newline, when the `:multimodal` option
  is `true`, else an empty string.
  """
  @spec faithfulness_verdicts_example_multimodal(keyword()) :: String.t()
  def faithfulness_verdicts_example_multimodal(opts) do
    if Keyword.get(opts, :multimodal, false) do
      """

      Example retrieval contexts: "Einstein won the Nobel Prize for his discovery of the photoelectric effect. Einstein won the Nobel Prize in 1968. Einstein is a German Scientist."
      Example claims: ["Barack Obama is a caucasian male.", "Zurich is a city in London", "Einstein won the Nobel Prize for the discovery of the photoelectric effect which may have contributed to his fame.", "Einstein won the Nobel Prize in 1969 for his discovery of the photoelectric effect.", "Einstein was a German chef."]

      Example:
      {
      "verdicts": [
      {
      "reason": "The claim about Barack Obama is not directly addressed in the retrieval context, and so poses no contradiction.",
      "verdict": "borderline"
      },
      {
      "reason": "The claim about Zurich being a city in London is incorrect but does not pose a contradiction to the retrieval context.",
      "verdict": "borderline"
      },
      {
      "verdict": "yes"
      },
      {
      "reason": "The actual output claims Einstein won the Nobel Prize in 1969, which is untrue as the retrieval context states it is 1968 instead.",
      "verdict": "no"
      },
      {
      "reason": "The actual output claims Einstein is a German chef, which is not correct as the retrieval context states he was a German scientist instead.",
      "verdict": "no"
      }
      ]  
      }
      ===== END OF EXAMPLE ======
      """
    else
      ""
    end
  end

  @doc """
  deepeval's `{% if multimodal %}{{ _fragments.faithfulness_verdicts_guidelines_multimodal }}{% endif %}{% if not multimodal %}{{ _fragments.faithfulness_verdicts_guidelines_text_only }}{% endif %}`
  in FaithfulnessMetric's verdicts template: the multimodal guidelines when
  the `:multimodal` option is `true`, else the text-only ones, each
  between a leading and a trailing newline.
  """
  @spec faithfulness_verdicts_guidelines(keyword()) :: String.t()
  def faithfulness_verdicts_guidelines(opts) do
    if Keyword.get(opts, :multimodal, false) do
      """

      The length of 'verdicts' SHOULD BE STRICTLY EQUAL to that of claims.
      You DON'T have to provide a reason if the answer is 'yes'.
      ONLY provide a 'no' answer if the retrieval context DIRECTLY CONTRADICTS the claims. YOU SHOULD NEVER USE YOUR PRIOR KNOWLEDGE IN YOUR JUDGEMENT.
      Claims made using vague, suggestive, speculative language such as 'may have', 'possibility due to', does NOT count as a contradiction.
      Claims that is not backed up due to a lack of information/is not mentioned in the retrieval contexts MUST be answered 'borderline'.
      If there are clear contradictions or any data or images that's not mentioned in the retrieval context, just provide 'no'.
      """
    else
      """

      Generate ONE verdict per claim - length of 'verdicts' MUST equal number of claims.
      No 'reason' needed for 'yes' verdicts.
      Only use 'no' if retrieval context DIRECTLY CONTRADICTS the claim - never use prior knowledge.
      Use 'borderline' for claims not backed up by context OR factually incorrect but non-contradictory - do not assume your knowledge.
      Vague/speculative language in claims (e.g. 'may have', 'possibility') does NOT count as contradiction.
      """
    end
  end

  @doc """
  deepeval's `{% if multimodal %}{{ _fragments.multimodal_input_rules_turn_metric }}{% endif %}`,
  the multimodal input rules of the Turn RAG metrics' templates: the rules,
  between a leading and a trailing newline, when the `:multimodal` option
  is `true`, else an empty string, so the blank lines around the fragment
  stay.

  ## Examples

      iex> DeepEvalEx.Prompts.Fragments.multimodal_input_rules_turn_metric([])
      ""
  """
  @spec multimodal_input_rules_turn_metric(keyword()) :: String.t()
  def multimodal_input_rules_turn_metric(opts) do
    if Keyword.get(opts, :multimodal, false) do
      """

      --- MULTIMODAL INPUT RULES ---
      - Treat image content as factual evidence.
      - Only reference visual details that are explicitly and clearly visible.
      - Do not infer or guess objects, text, or details not visibly present.
      - If an image is unclear or ambiguous, mark uncertainty explicitly.
      - When evaluating claims, compare them to BOTH textual and visual evidence.
      - If the claim references something not clearly visible, respond with 'borderline'.
      """
    else
      ""
    end
  end
end
