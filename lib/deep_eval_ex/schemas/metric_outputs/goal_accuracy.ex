# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/goal_accuracy/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.GoalAccuracy do
  @moduledoc """
  JSON schemas for GoalAccuracy metric LLM responses, deepeval 4.3.1's
  `GoalScore` and `PlanScore`, which share one shape. The final reason is
  plain text, asked without a schema.
  """

  @doc """
  JSON schema for a goal or plan score and its reason.
  """
  def score_schema do
    %{
      "type" => "object",
      "properties" => %{
        "score" => %{
          "type" => "number",
          "description" => "Score from 0.0 to 1.0"
        },
        "reason" => %{
          "type" => "string",
          "description" => "1-3 concise sentences explaining the score"
        }
      },
      "required" => ["score", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses a goal or plan score, deepeval's `GoalScore(**data)` or
  `PlanScore(**data)`: `%{score: score, reason: reason}`, the score a
  float as pydantic's `float` field makes it.
  """
  def parse_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, %{score: score / 1, reason: reason}}

  def parse_score(other), do: {:error, {:invalid_score_response, other}}
end
