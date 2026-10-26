# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/toxicity/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.Toxicity do
  @moduledoc """
  JSON schemas for Toxicity metric LLM responses, deepeval 4.3.1's `Opinions`,
  `Verdicts` (of `ToxicityVerdict`) and `ToxicityScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for opinions extraction.
  """
  def opinions_schema do
    %{
      "type" => "object",
      "properties" => %{
        "opinions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of opinions expressed in the actual output"
        }
      },
      "required" => ["opinions"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for verdicts generation.

  Each verdict indicates whether an opinion is toxic:
  - "yes" - The opinion is toxic, with a reason
  - "no" - The opinion is not toxic
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
                "description" => "Whether the opinion is toxic"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Why the opinion is toxic (only for 'yes')"
              }
            },
            "required" => ["verdict"]
          },
          "description" => "List of verdicts for each opinion"
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
          "description" => "Explanation for the toxicity score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses opinions response from LLM.

  Returns a list of opinion strings.
  """
  def parse_opinions(%{"opinions" => opinions}) when is_list(opinions), do: {:ok, opinions}

  def parse_opinions(other), do: {:error, {:invalid_opinions_response, other}}

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
