# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/conversation_completeness/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ConversationCompleteness do
  @moduledoc """
  JSON schemas for ConversationCompleteness metric LLM responses, deepeval
  4.3.1's `UserIntentions`, `ConversationCompletenessVerdict` and
  `ConversationCompletenessScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for user intention extraction.
  """
  def intentions_schema do
    %{
      "type" => "object",
      "properties" => %{
        "intentions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "The user's intentions in the conversation"
        }
      },
      "required" => ["intentions"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for the verdict on one user intention: whether the
  conversation satisfies it (`"yes"`) or not (`"no"`, with a reason).
  """
  def verdict_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{
          "type" => "string",
          "enum" => ["yes", "no"],
          "description" => "Whether the user intention was satisfied"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Why the intention was not satisfied (only for 'no')"
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
          "description" => "Explanation for the completeness score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the user intentions response from LLM: a list of strings.
  """
  def parse_intentions(%{"intentions" => intentions}) when is_list(intentions),
    do: {:ok, intentions}

  def parse_intentions(other), do: {:error, {:invalid_intentions_response, other}}

  @doc """
  Parses the verdict on one user intention with
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
