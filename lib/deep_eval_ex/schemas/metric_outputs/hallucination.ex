# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.Hallucination do
  @moduledoc """
  JSON schemas for Hallucination metric LLM responses.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for verdicts generation.

  Each verdict indicates whether the actual output agrees with a context:
  - "yes" - Agrees (factual alignment)
  - "no" - Contradicts (hallucination)
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
                "description" => "Whether the actual output agrees with the context"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for the verdict"
              }
            },
            "required" => ["verdict", "reason"]
          },
          "description" => "List of verdicts for each context"
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
          "description" => "Explanation for the hallucination score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses verdicts response from LLM.

  Returns a list of verdict maps with :verdict and :reason keys, normalised
  by `DeepEvalEx.Metrics.QAG.parse_verdicts/2`: verdicts other than yes and
  no are dropped.
  """
  def parse_verdicts(response), do: QAG.parse_verdicts(response, QAG.yes_no())

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
