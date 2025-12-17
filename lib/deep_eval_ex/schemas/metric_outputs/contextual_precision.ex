# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.ContextualPrecision do
  @moduledoc """
  JSON schemas for ContextualPrecision metric LLM responses.
  """

  @doc """
  JSON schema for verdicts generation.

  Each verdict indicates whether a retrieval context node was useful
  in arriving at the expected output:
  - "yes" - Useful/relevant node
  - "no" - Not useful/irrelevant node
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
              "verdict" => %{
                "type" => "string",
                "enum" => ["yes", "no"],
                "description" => "Whether the context node was useful for the expected output"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for the verdict"
              }
            },
            "required" => ["verdict", "reason"]
          },
          "description" => "List of verdicts for each retrieval context node"
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
          "description" => "Explanation for the contextual precision score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses verdicts response from LLM.

  Returns a list of verdict maps with :verdict and :reason keys.
  """
  def parse_verdicts(%{"verdicts" => verdicts}) when is_list(verdicts) do
    parsed =
      Enum.map(verdicts, fn verdict ->
        %{
          verdict: normalize_verdict(verdict["verdict"]),
          reason: verdict["reason"]
        }
      end)

    {:ok, parsed}
  end

  def parse_verdicts(other), do: {:error, {:invalid_verdicts_response, other}}

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}

  defp normalize_verdict(v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      "yes" -> :yes
      "no" -> :no
      _ -> :no
    end
  end

  defp normalize_verdict(_), do: :no
end
