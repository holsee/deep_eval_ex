# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/role_adherence/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.RoleAdherence do
  @moduledoc """
  JSON schemas for RoleAdherence metric LLM responses, deepeval 4.3.1's
  `OutOfCharacterResponseVerdicts` and `RoleAdherenceScoreReason`.
  """

  @doc """
  JSON schema for the out of character verdicts: one per assistant turn
  that breaks the chatbot role, by its index in the turns.
  """
  def verdicts_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdicts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "index" => %{
                "type" => "integer",
                "description" => "The index of the out of character turn"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Why the turn breaks the chatbot role"
              },
              "ai_message" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
            },
            "required" => ["index", "reason"]
          }
        }
      },
      "required" => ["verdicts"],
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
          "description" => "Explanation for the role adherence score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the out of character verdicts, deepeval's
  `OutOfCharacterResponseVerdicts(**data)`: each one
  `%{index: index, reason: reason, ai_message: ai_message}`, in order. A
  verdict without an integer `index` or a string `reason` fails the
  response, as pydantic's validation does.
  """
  def parse_verdicts(%{"verdicts" => verdicts} = response) when is_list(verdicts) do
    if Enum.all?(verdicts, &verdict?/1),
      do: {:ok, Enum.map(verdicts, &verdict/1)},
      else: {:error, {:invalid_verdicts_response, response}}
  end

  def parse_verdicts(other), do: {:error, {:invalid_verdicts_response, other}}

  defp verdict?(%{"index" => index, "reason" => reason} = verdict),
    do: is_integer(index) and is_binary(reason) and ai_message?(verdict["ai_message"])

  defp verdict?(_verdict), do: false

  defp ai_message?(message), do: is_nil(message) or is_binary(message)

  defp verdict(verdict),
    do: %{index: verdict["index"], reason: verdict["reason"], ai_message: verdict["ai_message"]}

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
