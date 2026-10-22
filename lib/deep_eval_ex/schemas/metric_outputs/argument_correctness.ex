# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/argument_correctness/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ArgumentCorrectness do
  @moduledoc """
  JSON schemas for ArgumentCorrectness metric LLM responses, deepeval
  4.3.1's `Verdicts` (of `ArgumentCorrectnessVerdict`) and
  `ArgumentCorrectnessScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for verdicts generation, one verdict per tool call:
  - "yes" - Its input parameters correctly address the input
  - "no" - They do not, or there are none, with a reason
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
                "description" =>
                  "Whether the tool call's input parameters correctly address the input"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Why the input parameters are incorrect (only for 'no')"
              }
            },
            "required" => ["verdict"]
          },
          "description" => "List of verdicts for each tool call"
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
          "description" => "Explanation for the argument correctness score"
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
