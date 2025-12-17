# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/answer_relevancy/template.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.AnswerRelevancy do
  @moduledoc """
  Prompt templates for the AnswerRelevancy metric.

  AnswerRelevancy measures whether the statements in an LLM's output
  are relevant to addressing the input question.
  """

  @doc """
  Generates a prompt to extract statements from the actual output.

  Statements are individual pieces of information that can be
  evaluated for relevance to the input.
  """
  def generate_statements(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)

    """
    Given the text, breakdown and generate a list of statements presented. Ambiguous statements and single words can be considered as statements, but only if outside of a coherent statement.

    Example:
    Example text:
    Our new laptop model features a high-resolution Retina display for crystal-clear visuals. It also includes a fast-charging battery, giving you up to 12 hours of usage on a single charge. For security, we've added fingerprint authentication and an encrypted SSD. Plus, every purchase comes with a one-year warranty and 24/7 customer support.

    {
        "statements": [
            "The new laptop model has a high-resolution Retina display.",
            "It includes a fast-charging battery with up to 12 hours of usage.",
            "Security features include fingerprint authentication and an encrypted SSD.",
            "Every purchase comes with a one-year warranty.",
            "24/7 customer support is included."
        ]
    }
    ===== END OF EXAMPLE ======

    **
    IMPORTANT: Please make sure to only return in valid and parseable JSON format, with the "statements" key mapping to a list of strings. No words or explanation are needed. Ensure all strings are closed appropriately. Repair any invalid JSON before you output it.
    **

    Text:
    #{actual_output}

    JSON:
    """
  end

  @doc """
  Generates a prompt to produce verdicts for each statement.

  Each verdict indicates whether the statement:
  - "yes" - Is relevant to addressing the input
  - "no" - Is irrelevant to the input
  - "idk" - Is ambiguous (supporting information)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    statements = Keyword.fetch!(opts, :statements)

    statements_formatted = format_statements(statements)

    """
    For the provided list of statements, determine whether each statement is relevant to address the input.
    Generate JSON objects with 'verdict' and 'reason' fields.
    The 'verdict' should be 'yes' (relevant), 'no' (irrelevant), or 'idk' (ambiguous/supporting information).
    Provide 'reason' ONLY for 'no' or 'idk' verdicts.
    The statements are from an AI's actual output.

    **
    IMPORTANT: Please make sure to only return in valid and parseable JSON format, with the 'verdicts' key mapping to a list of JSON objects. Ensure all strings are closed appropriately. Repair any invalid JSON before you output it.

    Expected JSON format:
    {
        "verdicts": [
            {
                "verdict": "yes"
            },
            {
                "reason": "<explanation_for_irrelevance>",
                "verdict": "no"
            },
            {
                "reason": "<explanation_for_ambiguity>",
                "verdict": "idk"
            }
        ]
    }

    Generate ONE verdict per statement - number of 'verdicts' MUST equal number of statements.
    'verdict' must be STRICTLY 'yes', 'no', or 'idk':
    - 'yes': statement is relevant to addressing the input
    - 'no': statement is irrelevant to the input
    - 'idk': statement is ambiguous (not directly relevant but could be supporting information)
    Provide 'reason' ONLY for 'no' or 'idk' verdicts.
    **

    Input:
    #{input}

    Statements:
    #{statements_formatted}

    JSON:
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.
  """
  def generate_reason(opts) do
    score = Keyword.fetch!(opts, :score)
    input = Keyword.fetch!(opts, :input)
    irrelevant_statements = Keyword.fetch!(opts, :irrelevant_statements)

    score_formatted = Float.round(score * 1.0, 2)
    irrelevant_formatted = format_irrelevant_statements(irrelevant_statements)

    """
    Given the answer relevancy score, the list of reasons of irrelevant statements made in the actual output, and the input, provide a CONCISE reason for the score. Explain why it is not higher, but also why it is at its current score.
    The irrelevant statements represent things in the actual output that is irrelevant to addressing whatever is asked/talked about in the input.
    If there is nothing irrelevant, just say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason. Ensure all strings are closed appropriately. Repair any invalid JSON before you output it.

    Example:
    Example JSON:
    {
        "reason": "The score is <answer_relevancy_score> because <your_reason>."
    }
    ===== END OF EXAMPLE ======
    **


    Answer Relevancy Score:
    #{score_formatted}

    Reasons why the score can't be higher based on irrelevant statements in the actual output:
    #{irrelevant_formatted}

    Input:
    #{input}

    JSON:
    """
  end

  defp format_statements(statements) when is_list(statements) do
    statements
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {statement, i} -> "#{i}. #{statement}" end)
  end

  defp format_irrelevant_statements([]), do: "(none)"

  defp format_irrelevant_statements(statements) when is_list(statements) do
    statements
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{s}" end)
  end
end
