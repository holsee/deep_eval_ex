# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/turn_relevancy/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.TurnRelevancy do
  @moduledoc """
  JSON schemas for TurnRelevancy metric LLM responses, deepeval 4.3.1's
  `TurnRelevancyVerdict` and `TurnRelevancyScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for the verdict on one sliding window: whether its last
  assistant turn is relevant (`"yes"`) or not (`"no"`, with a reason).
  """
  def verdict_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{
          "type" => "string",
          "enum" => ["yes", "no"],
          "description" => "Whether the last assistant message is relevant"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Why the message is irrelevant (only for 'no')"
        }
      },
      "required" => ["verdict"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for reason generation.
  """
  def reason_schema do
    %{
      "type" => "object",
      "properties" => %{
        "reason" => %{
          "type" => "string",
          "description" => "Explanation for the relevancy score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the verdict on one sliding window with
  `DeepEvalEx.Metrics.QAG.verdict_from_json/2`: `nil` for a verdict other
  than yes and no, which is dropped from scoring.
  """
  def parse_verdict(%{} = response), do: {:ok, QAG.verdict_from_json(response, QAG.yes_no())}
  def parse_verdict(other), do: {:error, {:invalid_verdict_response, other}}

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
