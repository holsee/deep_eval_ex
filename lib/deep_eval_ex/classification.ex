# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/api.py (Classification) and
# deepeval/evaluate/utils.py (create_classification)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Classification do
  @moduledoc """
  One classifier's result on one test case, deepeval 4.3.1's
  `Classification`: the classifier counterpart of a metric's
  `DeepEvalEx.Result`.

  `DeepEvalEx.Classifier.classify/3` returns one, and
  `DeepEvalEx.TestResult` carries one per classifier as `:classifications`.
  Like deepeval's, classifications are local only: they decide the
  `DeepEvalEx.TestResult`'s success but are never written to a
  `DeepEvalEx.TestRun`.

  ## Fields

  - `:name` - The classifier's name
  - `:label` - The label it assigned, `nil` when it errored or, with
    `allow_none`, declined to classify
  - `:expected_label` - The test case's `expected_labels[name]`, if any
  - `:success` - `nil` without an expected label (no verdict), `false`
    when the classifier errored, else whether `:label` is the expected
    label (see `DeepEvalEx.Classifier.success/2`)
  - `:reason` - Why the label was chosen; `nil` when the classifier errored
    or was built with `include_reason: false`
  - `:evaluation_model` - The judge: the LLM's name under `:llm`, the
    System One model's under `:system_one`
  - `:error` - The error message, when the classifier errored
  - `:evaluation_cost`, `:input_tokens`, `:output_tokens` - Usage, seeded
    as a metric's (`0` for a native judge or System One, `nil` for a custom
    judge); a classification this run cached (`DeepEvalEx.TestRun.Cache`)
    costs the integer `0`, as deepeval caches it
  """

  alias DeepEvalEx.Prompts.Python
  alias Jason.OrderedObject

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t() | nil,
          expected_label: String.t() | nil,
          success: boolean() | nil,
          reason: String.t() | nil,
          evaluation_model: String.t() | nil,
          error: String.t() | nil,
          evaluation_cost: number() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :label,
    :expected_label,
    :success,
    :reason,
    :evaluation_model,
    :error,
    :evaluation_cost,
    :input_tokens,
    :output_tokens
  ]

  @doc """
  The classification as deepeval dumps it (`model_dump(by_alias=True)`):
  every field under its camelCase alias, in deepeval's field order, the
  cost as a float.

  ## Examples

      iex> classification = %DeepEvalEx.Classification{name: "refusal", label: "refused"}
      iex> DeepEvalEx.TestRun.JSON.encode!(DeepEvalEx.Classification.to_map(classification))
      ~s({"name": "refusal", "label": "refused", "expectedLabel": null, "success": null, "reason": null, "evaluationModel": null, "error": null, "evaluationCost": null, "inputTokenCount": null, "outputTokenCount": null})
  """
  @spec to_map(t()) :: OrderedObject.t()
  def to_map(%__MODULE__{} = classification) do
    OrderedObject.new([
      {"name", classification.name},
      {"label", classification.label},
      {"expectedLabel", classification.expected_label},
      {"success", classification.success},
      {"reason", classification.reason},
      {"evaluationModel", classification.evaluation_model},
      {"error", classification.error},
      {"evaluationCost", float(classification.evaluation_cost)},
      {"inputTokenCount", classification.input_tokens},
      {"outputTokenCount", classification.output_tokens}
    ])
  end

  @doc """
  The classification as `deepeval`'s `assert_test` names a failed one:
  `name (label: ..., expected: ..., error: ..., reason: ...)`, each value
  as Python's `str()`.

  ## Examples

      iex> DeepEvalEx.Classification.describe(%DeepEvalEx.Classification{
      ...>   name: "refusal", label: "complied", expected_label: "refused", reason: "Answered."})
      "refusal (label: complied, expected: refused, error: None, reason: Answered.)"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = c) do
    "#{c.name} (label: #{str(c.label)}, expected: #{str(c.expected_label)}, " <>
      "error: #{str(c.error)}, reason: #{str(c.reason)})"
  end

  defp str(nil), do: "None"
  defp str(value) when is_binary(value), do: value
  defp str(value), do: Python.repr(value)

  # Classification.evaluation_cost is a pydantic float.
  defp float(cost) when is_integer(cost), do: cost * 1.0
  defp float(cost), do: cost
end
