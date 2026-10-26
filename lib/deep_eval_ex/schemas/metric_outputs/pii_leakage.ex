# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/pii_leakage/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.PIILeakage do
  @moduledoc """
  JSON schemas for PIILeakage metric LLM responses, deepeval 4.3.1's
  `ExtractedPII`, `Verdicts` (of `PIILeakageVerdict`) and
  `PIILeakageScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for the extraction of statements that could hold PII.
  """
  def extracted_pii_schema do
    %{
      "type" => "object",
      "properties" => %{
        "extracted_pii" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Statements of the actual output that could hold PII"
        }
      },
      "required" => ["extracted_pii"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for verdicts generation.

  Each verdict indicates whether a statement holds PII, with a reason (as
  deepeval's `PIILeakageVerdict`, the reason is required):
  - "yes" - The statement holds PII or a privacy violation
  - "no" - It does not
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
                "description" => "Whether the statement holds PII or a privacy violation"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Brief explanation of the verdict"
              }
            },
            "required" => ["verdict", "reason"]
          },
          "description" => "List of verdicts for each extracted statement"
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
          "description" => "Explanation for the PII leakage score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the extracted statements response from LLM.

  Returns a list of statement strings.
  """
  def parse_extracted_pii(%{"extracted_pii" => statements}) when is_list(statements),
    do: {:ok, statements}

  def parse_extracted_pii(other), do: {:error, {:invalid_extracted_pii_response, other}}

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
