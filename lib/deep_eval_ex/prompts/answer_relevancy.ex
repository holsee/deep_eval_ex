# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/answer_relevancy/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.AnswerRelevancy do
  @moduledoc """
  Prompt templates for the AnswerRelevancy metric.

  AnswerRelevancy measures whether the statements in an LLM's output
  are relevant to addressing the input question.

  Each function renders deepeval 4.3.1's `AnswerRelevancyMetric` template
  of the same name byte for byte, as deepeval renders it for a text-only
  test case (`multimodal=False`): the multimodal input rules fragment is
  left out, as DeepEvalEx has no multimodal test cases. Lists are printed
  as Python lists and scores as `format(score, ".2f")` (see
  `DeepEvalEx.Prompts.Python`).
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract statements from the actual output.

  Statements are individual pieces of information that can be
  evaluated for relevance to the input.

  ## Options

  - `:actual_output` - the text to break into statements (required)
  """
  def generate_statements(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)

    """
    Given the text, breakdown and generate a list of statements presented. Ambiguous statements and single words can be considered as statements, but only if outside of a coherent statement.

    Example:
    Example text: 
    Our new laptop model features a high-resolution Retina display for crystal-clear visuals. It also includes a fast-charging battery, giving you up to 12 hours of usage on a single charge. For security, we’ve added fingerprint authentication and an encrypted SSD. Plus, every purchase comes with a one-year warranty and 24/7 customer support.



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

    JSON:\
    """
  end

  @doc """
  Generates a prompt to produce verdicts for each statement.

  Each verdict indicates whether the statement:
  - "yes" - Is relevant to addressing the input
  - "no" - Is irrelevant to the input
  - "borderline" - Is ambiguous (supporting information)

  ## Options

  - `:input` - the test case input (required)
  - `:statements` - the statements, a list of strings (required)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    statements = opts |> Keyword.fetch!(:statements) |> Python.repr()

    """
    For the provided list of statements, determine whether each statement is relevant to address the input.
    Generate JSON objects with 'verdict' and 'reason' fields.
    The 'verdict' should be 'yes' (relevant), 'no' (irrelevant), or 'borderline' (ambiguous/supporting information).
    Provide 'reason' ONLY for 'no' or 'borderline' verdicts.
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
          "reason": <explanation_for_irrelevance>,
          "verdict": "no"
        },
        {
          "reason": <explanation_for_ambiguity>,
          "verdict": "borderline"
        }
      ]  
    }

    Generate ONE verdict per statement - number of 'verdicts' MUST equal number of statements.
    'verdict' must be STRICTLY 'yes', 'no', or 'borderline':
    - 'yes': statement is relevant to addressing the input
    - 'no': statement is irrelevant to the input  
    - 'borderline': statement is ambiguous (not directly relevant but could be supporting information)
    Provide 'reason' ONLY for 'no' or 'borderline' verdicts.
    **          

    Input:
    #{input}

    Statements:
    #{statements}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the answer relevancy score (required)
  - `:input` - the test case input (required)
  - `:irrelevant_statements` - the reasons of the `"no"` verdicts
    (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    input = Keyword.fetch!(opts, :input)
    irrelevant_statements = opts |> Keyword.fetch!(:irrelevant_statements) |> Python.repr()

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
    #{score}

    Reasons why the score can't be higher based on irrelevant statements in the actual output:
    #{irrelevant_statements}

    Input:
    #{input}

    JSON:\
    """
  end
end
