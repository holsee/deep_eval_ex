# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/plan_adherence/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.PlanAdherence do
  @moduledoc """
  JSON schemas for PlanAdherence metric LLM responses, deepeval 4.3.1's
  `AgentPlan` and `PlanAdherenceScore`. PlanQuality extracts its plan with
  the same `AgentPlan`.
  """

  @doc """
  JSON schema for the plan extracted from the trace.
  """
  def plan_schema do
    %{
      "type" => "object",
      "properties" => %{
        "plan" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "The plan's steps, in order; empty when the trace states no plan"
        }
      },
      "required" => ["plan"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for the score and its reason.
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
          "description" => "1-3 concise, factual sentences citing matched, missing or extra steps"
        }
      },
      "required" => ["score", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the extracted plan, deepeval's `AgentPlan`: its list of steps.
  """
  def parse_plan(%{"plan" => plan} = response) when is_list(plan) do
    if Enum.all?(plan, &is_binary/1),
      do: {:ok, plan},
      else: {:error, {:invalid_plan_response, response}}
  end

  def parse_plan(other), do: {:error, {:invalid_plan_response, other}}

  @doc """
  Parses the score, deepeval's `PlanAdherenceScore`:
  `%{score: score, reason: reason}`, the score a float as pydantic's
  `float` field makes it.
  """
  def parse_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, %{score: score / 1, reason: reason}}

  def parse_score(other), do: {:error, {:invalid_score_response, other}}
end
