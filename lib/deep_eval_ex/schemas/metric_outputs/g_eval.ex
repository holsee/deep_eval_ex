# Copyright 2024 DeepEvalEx Contributors
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.GEval do
  @moduledoc """
  JSON schemas for GEval metric LLM responses.
  """

  @doc """
  JSON schema for evaluation steps generation.

  Expected response:
  ```json
  {"steps": ["Step 1: ...", "Step 2: ...", "Step 3: ..."]}
  ```
  """
  def steps_schema do
    %{
      "type" => "object",
      "properties" => %{
        "steps" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of evaluation steps"
        }
      },
      "required" => ["steps"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for evaluation results.

  Expected response:
  ```json
  {"score": 8, "reason": "The response is accurate and helpful..."}
  ```
  """
  def reason_score_schema do
    %{
      "type" => "object",
      "properties" => %{
        "score" => %{
          "type" => "integer",
          "description" => "Evaluation score"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Explanation for the score"
        }
      },
      "required" => ["score", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the steps response from LLM.
  """
  def parse_steps(%{"steps" => steps}) when is_list(steps), do: {:ok, steps}
  def parse_steps(other), do: {:error, {:invalid_steps_response, other}}

  @doc """
  Parses the score/reason response from LLM.
  """
  def parse_reason_score(%{"score" => score, "reason" => reason})
      when is_integer(score) and is_binary(reason) do
    {:ok, {score, reason}}
  end

  def parse_reason_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason) do
    {:ok, {round(score), reason}}
  end

  def parse_reason_score(other), do: {:error, {:invalid_reason_score_response, other}}
end
