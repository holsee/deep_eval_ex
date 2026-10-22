# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.AnswerRelevancy do
  @moduledoc """
  JSON schemas for AnswerRelevancy metric LLM responses.
  """

  alias DeepEvalEx.Metrics.QAG

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
  - "borderline" - Ambiguous/supporting information
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
                "enum" => ["yes", "no", "borderline"],
                "description" => "Whether the statement is relevant to the input"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for the verdict (only for 'no' or 'borderline')"
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

  Returns a list of verdict maps with :verdict and optional :reason keys,
  normalised by `DeepEvalEx.Metrics.QAG.parse_verdicts/2`: `idk` is read as
  `borderline` and verdicts outside yes/no/borderline are dropped.
  """
  def parse_verdicts(response), do: QAG.parse_verdicts(response, QAG.yes_no_borderline())

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
