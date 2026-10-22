# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/tool_use/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ToolUse do
  @moduledoc """
  JSON schemas for ToolUse metric LLM responses, deepeval 4.3.1's
  `ToolSelectionScore` and `ArgumentCorrectnessScore`, which share one
  shape, and `Reason`.
  """

  @doc """
  JSON schema for a tool selection or argument correctness score and its
  reason.
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
  JSON schema for a final reason.
  """
  def reason_schema do
    %{
      "type" => "object",
      "properties" => %{
        "reason" => %{
          "type" => "string",
          "description" => "Explanation for the tool use score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses a tool selection or argument correctness score, deepeval's
  `ToolSelectionScore(**data)` or `ArgumentCorrectnessScore(**data)`:
  `%{score: score, reason: reason}`, the score a float as pydantic's
  `float` field makes it.
  """
  def parse_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, %{score: score / 1, reason: reason}}

  def parse_score(other), do: {:error, {:invalid_score_response, other}}

  @doc """
  Parses a final reason, deepeval's `Reason(**data).reason`.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
