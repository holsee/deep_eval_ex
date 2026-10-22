# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.MetricOutputs.Faithfulness do
  @moduledoc """
  JSON schemas for Faithfulness metric LLM responses.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for claims extraction.
  """
  def claims_schema do
    %{
      "type" => "object",
      "properties" => %{
        "claims" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of factual claims from the output"
        }
      },
      "required" => ["claims"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for truths extraction.
  """
  def truths_schema do
    %{
      "type" => "object",
      "properties" => %{
        "truths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of factual truths from the context"
        }
      },
      "required" => ["truths"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for verdicts generation.
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
                "description" => "Whether the claim is supported by context"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for no/borderline verdicts"
              }
            },
            "required" => ["verdict"]
          },
          "description" => "List of verdicts for each claim"
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
          "description" => "Explanation for the faithfulness score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses claims response from LLM.
  """
  def parse_claims(%{"claims" => claims}) when is_list(claims), do: {:ok, claims}
  def parse_claims(other), do: {:error, {:invalid_claims_response, other}}

  @doc """
  Parses truths response from LLM.
  """
  def parse_truths(%{"truths" => truths}) when is_list(truths), do: {:ok, truths}
  def parse_truths(other), do: {:error, {:invalid_truths_response, other}}

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
