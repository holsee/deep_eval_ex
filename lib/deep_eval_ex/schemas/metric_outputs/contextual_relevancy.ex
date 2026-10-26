# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/contextual_relevancy/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.ContextualRelevancy do
  @moduledoc """
  JSON schemas for ContextualRelevancy metric LLM responses, deepeval
  4.3.1's `ContextualRelevancyVerdicts` and `ContextualRelevancyScoreReason`.
  """

  alias DeepEvalEx.Metrics.QAG

  @typedoc """
  A parsed verdict, deepeval's `ContextualRelevancyVerdict`: a statement of
  a retrieval context node, whether it is relevant to the input and, for an
  irrelevant one, why.
  """
  @type verdict :: %{statement: String.t(), verdict: QAG.verdict(), reason: String.t() | nil}

  @doc """
  JSON schema for the verdicts of one retrieval context node.

  Each verdict names a statement found in the node and whether it is
  relevant to the input:
  - "yes" - The statement is relevant to the input
  - "no" - The statement is irrelevant, with a reason quoting it
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
              "statement" => %{
                "type" => "string",
                "description" => "A statement found in the context"
              },
              "verdict" => %{
                "type" => "string",
                "enum" => ["yes", "no"],
                "description" => "Whether the statement is relevant to the input"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Why the statement is irrelevant (only for 'no')"
              }
            },
            "required" => ["statement", "verdict"]
          },
          "description" => "List of verdicts for each statement in the context"
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
          "description" => "Explanation for the contextual relevancy score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the verdicts of one retrieval context node from the LLM.

  Returns a list of `t:verdict/0` maps, each verdict normalised by
  `DeepEvalEx.Metrics.QAG.normalize_qag_verdict/2`: verdicts other than yes
  and no are dropped, as deepeval drops them. A kept verdict without a
  string statement is an invalid response, as it fails deepeval's schema.
  """
  @spec parse_verdicts(term()) :: {:ok, [verdict()]} | {:error, term()}
  def parse_verdicts(%{"verdicts" => verdicts} = response) when is_list(verdicts) do
    verdicts
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_verdict(item) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, verdict} -> {:cont, {:ok, [verdict | acc]}}
        :error -> {:halt, {:error, {:invalid_verdicts_response, response}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  def parse_verdicts(other), do: {:error, {:invalid_verdicts_response, other}}

  # As deepeval's verdict_from_json, a verdict outside yes and no is dropped
  # before the statement is checked.
  defp parse_verdict(%{} = item) do
    case {QAG.normalize_qag_verdict(item["verdict"], QAG.yes_no()), item["statement"]} do
      {nil, _statement} -> {:ok, nil}
      {verdict, statement} when is_binary(statement) -> {:ok, verdict(statement, verdict, item)}
      _invalid -> :error
    end
  end

  defp parse_verdict(_item), do: {:ok, nil}

  defp verdict(statement, verdict, item),
    do: %{statement: statement, verdict: verdict, reason: item["reason"]}

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
