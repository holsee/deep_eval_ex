# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/task_completion/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.TaskCompletion do
  @moduledoc """
  JSON schemas for TaskCompletion metric LLM responses, deepeval 4.3.1's
  `TaskAndOutcome` and `TaskCompletionVerdict`.
  """

  @doc """
  JSON schema for the extracted task and its outcome.
  """
  def task_and_outcome_schema do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "The task or objective the user wants to achieve"
        },
        "outcome" => %{
          "type" => "string",
          "description" => "A strictly factual description of what the system did"
        }
      },
      "required" => ["task", "outcome"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for the verdict on how well the outcome achieves the task.
  """
  def verdict_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{
          "type" => "number",
          "description" => "Score from 0 to 1"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Why the verdict was assigned"
        }
      },
      "required" => ["verdict"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the extracted task and outcome, deepeval's `TaskAndOutcome`:
  `{task, outcome}`.
  """
  def parse_task_and_outcome(%{"task" => task, "outcome" => outcome})
      when is_binary(task) and is_binary(outcome),
      do: {:ok, {task, outcome}}

  def parse_task_and_outcome(other), do: {:error, {:invalid_task_and_outcome_response, other}}

  @doc """
  Parses the verdict, deepeval's `TaskCompletionVerdict`:
  `{verdict, reason}`, the verdict a float as pydantic's `float` field
  makes it and the reason `nil` when absent, as its optional field
  defaults.
  """
  def parse_verdict(%{"verdict" => verdict} = response) when is_number(verdict) do
    case Map.get(response, "reason") do
      reason when is_binary(reason) or is_nil(reason) -> {:ok, {verdict / 1, reason}}
      _other -> {:error, {:invalid_verdict_response, response}}
    end
  end

  def parse_verdict(other), do: {:error, {:invalid_verdict_response, other}}
end
