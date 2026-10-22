# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/conversational_g_eval/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ConversationalGEval do
  @moduledoc """
  JSON schemas for ConversationalGEval metric LLM responses, deepeval
  4.3.1's `Steps` and `ReasonScore`.

  Unlike GEval's, the score is a number, as deepeval's `score: float`: a
  fractional score is kept, not rounded.
  """

  alias DeepEvalEx.Schemas.MetricOutputs.GEval

  @doc """
  JSON schema for evaluation steps generation, GEval's (see
  `DeepEvalEx.Schemas.MetricOutputs.GEval.steps_schema/0`).
  """
  defdelegate steps_schema, to: GEval

  @doc """
  Parses the steps response from LLM.
  """
  defdelegate parse_steps(response), to: GEval

  @doc """
  JSON schema for the evaluation result.

  Expected response:
  ```json
  {"reason": "The assistant resolves the request...", "score": 8}
  ```
  """
  def reason_score_schema do
    %{
      "type" => "object",
      "properties" => %{
        "reason" => %{
          "type" => "string",
          "description" => "Explanation for the score"
        },
        "score" => %{
          "type" => "number",
          "description" => "Evaluation score, from 0 to 10"
        }
      },
      "required" => ["reason", "score"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the score/reason response from LLM, keeping the score as given.

  ## Examples

      iex> DeepEvalEx.Schemas.MetricOutputs.ConversationalGEval.parse_reason_score(
      ...>   %{"reason" => "Partly.", "score" => 2.5}
      ...> )
      {:ok, {2.5, "Partly."}}
  """
  def parse_reason_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, {score, reason}}

  def parse_reason_score(other), do: {:error, {:invalid_reason_score_response, other}}
end
