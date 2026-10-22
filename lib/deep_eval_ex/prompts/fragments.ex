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
