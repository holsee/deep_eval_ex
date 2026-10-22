# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/summarization/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.Summarization do
  @moduledoc """
  JSON schemas for Summarization metric LLM responses, deepeval 4.3.1's
  `Questions`, `Answers`, `Verdicts` (of `SummarizationAlignmentVerdict`)
  and `SummarizationScoreReason`.

  The truths and claims are extracted with the Faithfulness schemas
  (`DeepEvalEx.Schemas.MetricOutputs.Faithfulness`), as deepeval borrows
  `Truths` and `Claims`.
  """

  alias DeepEvalEx.Metrics.QAG

  @doc """
  JSON schema for assessment question generation.
  """
  def questions_schema do
    %{
      "type" => "object",
      "properties" => %{
        "questions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Closed-ended questions the original text answers with 'yes'"
        }
      },
      "required" => ["questions"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for answer generation: one `"yes"` or `"no"` per assessment
  question. As in deepeval, the answers are free strings.
  """
  def answers_schema do
    %{
      "type" => "object",
      "properties" => %{
        "answers" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Whether the text can answer each question, 'yes' or 'no'"
        }
      },
      "required" => ["answers"],
      "additionalProperties" => false
    }
  end

  @doc """
  JSON schema for alignment verdicts generation, one verdict per claim of
  the summary:
  - "yes" - The claim agrees with the original text
  - "no" - It contradicts the original text
  - "borderline" - The original text does not back it up
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
                "description" => "Whether the summary claim agrees with the original text"
              },
              "reason" => %{
                "type" => "string",
                "description" => "Explanation for no/borderline verdicts"
              }
            },
            "required" => ["verdict"]
          },
          "description" => "List of verdicts for each summary claim"
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
          "description" => "Explanation for the summarization score"
        }
      },
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses questions response from LLM.
  """
  def parse_questions(%{"questions" => questions}) when is_list(questions) do
    if Enum.all?(questions, &is_binary/1),
      do: {:ok, questions},
      else: {:error, {:invalid_questions_response, questions}}
  end

  def parse_questions(other), do: {:error, {:invalid_questions_response, other}}

  @doc """
  Parses answers response from LLM.
  """
  def parse_answers(%{"answers" => answers}) when is_list(answers) do
    if Enum.all?(answers, &is_binary/1),
      do: {:ok, answers},
      else: {:error, {:invalid_answers_response, answers}}
  end

  def parse_answers(other), do: {:error, {:invalid_answers_response, other}}

  @doc """
  Parses verdicts response from LLM.

  Returns a list of verdict maps with :verdict and :reason keys, normalised
  by `DeepEvalEx.Metrics.QAG.parse_verdicts/2`: `idk` is read as
  `borderline` and verdicts outside yes/no/borderline are dropped.
  """
  def parse_verdicts(response), do: QAG.parse_verdicts(response, QAG.yes_no_borderline())

  @doc """
  Parses reason response from LLM.
  """
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
