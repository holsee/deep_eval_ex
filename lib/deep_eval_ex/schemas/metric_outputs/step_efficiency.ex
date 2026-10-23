# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/step_efficiency/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.StepEfficiency do
  @moduledoc """
  JSON schemas for StepEfficiency metric LLM responses, deepeval 4.3.1's
  `Task` and `EfficiencyVerdict`.
  """

  @doc """
  JSON schema for the task extracted from the trace.
  """
  def task_schema do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "A single clear sentence summarizing the user's explicit goal"
        }
      },
      "required" => ["task"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for the efficiency score and its reason.
  """
  def efficiency_schema do
    %{
      "type" => "object",
      "properties" => %{
        "score" => %{
          "type" => "number",
          "description" => "Score from 0.0 to 1.0"
        },
        "reason" => %{
          "type" => "string",
          "description" =>
            "1-3 concise factual sentences describing where inefficiencies occurred"
        }
      },
      "required" => ["score", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the extracted task, deepeval's `Task`.
  """
  def parse_task(%{"task" => task}) when is_binary(task), do: {:ok, task}
  def parse_task(other), do: {:error, {:invalid_task_response, other}}

  @doc """
  Parses the efficiency verdict, deepeval's `EfficiencyVerdict`:
  `%{score: score, reason: reason}`, the score a float as pydantic's
  `float` field makes it.
  """
  def parse_efficiency(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, %{score: score / 1, reason: reason}}

  def parse_efficiency(other), do: {:error, {:invalid_efficiency_response, other}}
end
