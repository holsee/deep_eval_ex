# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/plan_quality/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.PlanQuality do
  @moduledoc """
  JSON schema for the PlanQuality metric's score, deepeval 4.3.1's
  `PlanQualityScore`. Its `AgentPlan` is PlanAdherence's
  (`DeepEvalEx.Schemas.MetricOutputs.PlanAdherence.plan_schema/0`).
  """

  @doc """
  JSON schema for the plan quality score and its reason.
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
          "description" =>
            "1-3 short, precise sentences on what the plan lacks or how it could fail"
        }
      },
      "required" => ["score", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the score, deepeval's `PlanQualityScore`:
  `%{score: score, reason: reason}`, the score a float as pydantic's
  `float` field makes it.
  """
  def parse_score(%{"score" => score, "reason" => reason})
      when is_number(score) and is_binary(reason),
      do: {:ok, %{score: score / 1, reason: reason}}

  def parse_score(other), do: {:error, {:invalid_score_response, other}}
end
