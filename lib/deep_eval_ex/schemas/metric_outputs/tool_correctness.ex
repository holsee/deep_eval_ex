# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/tool_correctness/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ToolCorrectness do
  @moduledoc """
  JSON schemas for ToolCorrectness metric LLM responses.
  """

  @doc """
  JSON schema for tool selection score evaluation.
  """
  def tool_selection_score_schema do
    %{
      "type" => "object",
      "properties" => %{
        "score" => %{
          "type" => "number",
          "description" => "Tool selection score from 0.0 to 1.0"
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
  Parses tool selection score response from LLM.
  """
  def parse_tool_selection_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason) do
    {:ok, %{score: score / 1, reason: reason}}
  end

  def parse_tool_selection_score(other) do
    {:error, {:invalid_tool_selection_response, other}}
  end
end
