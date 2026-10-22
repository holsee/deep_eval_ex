# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/knowledge_retention/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.KnowledgeRetention do
  @moduledoc """
  JSON schemas for KnowledgeRetention metric LLM responses, deepeval
  4.3.1's `Knowledge`, `KnowledgeRetentionVerdict` and
  `KnowledgeRetentionScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG
  alias Jason.OrderedObject

  @doc """
  JSON schema for the facts one user turn states: `data`, a dict of
  strings or lists of strings, or `null` when it states none.
  """
  def knowledge_schema do
    %{
      "type" => "object",
      "properties" => %{
        "data" => %{
          "anyOf" => [
            %{
              "type" => "object",
              "additionalProperties" => %{
                "anyOf" => [
                  %{"type" => "string"},
                  %{"type" => "array", "items" => %{"type" => "string"}}
                ]
              }
            },
            %{"type" => "null"}
          ],
          "description" => "The facts the latest user message states"
        }
      },
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for the verdict on one assistant turn: whether it forgets or
  contradicts a known fact (`"yes"`) or not (`"no"`), with an optional
  reason.
  """
  def verdict_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{
          "type" => "string",
          "enum" => ["yes", "no"],
          "description" => "Whether the message forgets or contradicts a known fact"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Why, with a correction where possible"
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
          "description" => "Explanation for the knowledge retention score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the facts of one user turn, deepeval's `Knowledge(**data)`:
  `{:ok, %{data: data}}`, where `data` is `nil` when the judge answered
  `{}` or `null`. Maps keep the judge's dict as decoded; a
  `Jason.OrderedObject` keeps its key order, as the prompts print it.
  """
  def parse_knowledge(%OrderedObject{values: values}),
    do: values |> Map.new() |> parse_knowledge()

  def parse_knowledge(%{} = response) when map_size(response) == 0, do: {:ok, %{data: nil}}

  def parse_knowledge(%{"data" => data} = response) when map_size(response) == 1 do
    if is_nil(data) or facts?(data),
      do: {:ok, %{data: data}},
      else: {:error, {:invalid_knowledge_response, response}}
  end

  def parse_knowledge(other), do: {:error, {:invalid_knowledge_response, other}}

  defp facts?(%OrderedObject{values: values}), do: Enum.all?(values, &fact?/1)
  defp facts?(%{} = data) when not is_struct(data), do: Enum.all?(data, &fact?/1)
  defp facts?(_data), do: false

  defp fact?({key, value}) when is_binary(key),
    do: is_binary(value) or (is_list(value) and Enum.all?(value, &is_binary/1))

  defp fact?(_pair), do: false

  @doc """
  Parses the verdict on one assistant turn with
  `DeepEvalEx.Metrics.QAG.verdict_from_json/2`: `nil` for a verdict other
  than yes and no.
  """
  def parse_verdict(%{} = response), do: {:ok, QAG.verdict_from_json(response, QAG.yes_no())}
  def parse_verdict(other), do: {:error, {:invalid_verdict_response, other}}

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
