# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.AnswerRelevancy do
  @moduledoc """
  JSON schemas for AnswerRelevancy metric LLM responses.
  """

  @doc """
  JSON schema for statements extraction.
  """
  def statements_schema do
    %{
      "type" => "object",
      "properties" => %{
        "statements" => %{
          "type" => "array",
          "items" => %{
            "type" => "string"
          },
          "description" => "List of statements extracted from the actual output"
        }
      },
      "required" => ["statements"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for verdicts generation.

  Each verdict indicates whether a statement is relevant to the input:
  - "yes" - Relevant to addressing the input
  - "no" - Irrelevant to the input
  - "idk" - Ambiguous/supporting information
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
                "enum" => ["yes", "no", "idk"],
                "description" => "Whether the statement is relevant to the input"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for the verdict (only for 'no' or 'idk')"
              }
            },
            "required" => ["verdict"]
          },
          "description" => "List of verdicts for each statement"
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
          "description" => "Explanation for the answer relevancy score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses statements response from LLM.

  Returns a list of statement strings.
  """
  def parse_statements(%{"statements" => statements}) when is_list(statements) do
    {:ok, statements}
  end

  def parse_statements(other), do: {:error, {:invalid_statements_response, other}}

  @doc """
  Parses verdicts response from LLM.

  Returns a list of verdict maps with :verdict and optional :reason keys.
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
      "idk" -> :idk
      _ -> :no
    end
  end

  defp normalize_verdict(_), do: :no
end
