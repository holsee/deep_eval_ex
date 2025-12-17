# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/g_eval/template.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.GEval do
  @moduledoc """
  Prompt templates for the GEval metric.

  Based on the G-Eval framework: https://arxiv.org/pdf/2303.16634.pdf
  """

  @doc """
  Generates a prompt to create evaluation steps from criteria.

  The LLM will generate 3-4 concrete evaluation steps based on the
  provided criteria and parameters.
  """
  def generate_evaluation_steps(opts) do
    criteria = Keyword.fetch!(opts, :criteria)
    parameters = Keyword.fetch!(opts, :parameters)

    """
    Given an evaluation criteria which outlines how you should judge the #{parameters}, generate 3-4 concise evaluation steps based on the criteria below. You MUST make it clear how to evaluate #{parameters} in relation to one another.

    Evaluation Criteria:
    #{criteria}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "steps" key as a list of strings. No words or explanation is needed.
    Example JSON:
    {
        "steps": ["Step 1: ...", "Step 2: ...", "Step 3: ..."]
    }
    **

    JSON:
    """
  end

  @doc """
  Generates a prompt for evaluation using the generated steps.

  This is the main evaluation prompt that scores the test case
  based on the evaluation steps and optional rubric.
  """
  def generate_evaluation_results(opts) do
    evaluation_steps = Keyword.fetch!(opts, :evaluation_steps)
    test_case_content = Keyword.fetch!(opts, :test_case_content)
    parameters = Keyword.fetch!(opts, :parameters)
    rubric = Keyword.get(opts, :rubric)
    {score_min, score_max} = Keyword.get(opts, :score_range, {0, 10})

    rubric_text = if rubric, do: "Rubric:\n#{rubric}\n", else: ""

    dependencies =
      if rubric, do: "evaluation steps and rubric", else: "evaluation steps"

    score_explanation =
      if rubric do
        "based on the rubric provided"
      else
        "with #{score_max} indicating strong alignment with the evaluation steps and #{score_min} indicating no alignment"
      end

    reasoning_expectation =
      if rubric do
        "Be specific and grounded in the evaluation steps and rubric."
      else
        "Be specific and grounded in the evaluation steps."
      end

    steps_formatted = format_evaluation_steps(evaluation_steps)

    """
    You are an evaluator. Given the following #{dependencies}, assess the response below and return a JSON object with two fields:

    - `"score"`: an integer between #{score_min} and #{score_max}, #{score_explanation}.
    - `"reason"`: a brief explanation for why the score was given. This must mention specific strengths or shortcomings, referencing relevant details from the input. Do **not** quote the score itself in the explanation.

    Your explanation should:
    - #{reasoning_expectation}
    - Mention key details from the test case parameters.
    - Be concise, clear, and focused on the evaluation logic.

    Only return valid JSON. Do **not** include any extra commentary or text.

    ---

    Evaluation Steps:
    #{steps_formatted}

    #{rubric_text}
    Test Case:
    #{test_case_content}

    Parameters:
    #{parameters}

    ---
    **Example JSON:**
    {
        "reason": "your concise and informative reason here",
        "score": #{score_min}
    }

    JSON:
    """
  end

  @doc """
  Generates a prompt for strict (binary) evaluation.

  Returns either 0 or 1 based on whether the criteria is fully met.
  """
  def generate_strict_evaluation_results(opts) do
    evaluation_steps = Keyword.fetch!(opts, :evaluation_steps)
    test_case_content = Keyword.fetch!(opts, :test_case_content)
    parameters = Keyword.fetch!(opts, :parameters)

    steps_formatted = format_evaluation_steps(evaluation_steps)

    """
    Given the evaluation steps, return a JSON with two keys: 1) a `score` key that is STRICTLY EITHER 1 (follows the criteria 100% outlined in the evaluation steps), OR 0 (does not follow the criteria), and 2) a `reason` key, a reason for the given score, but DO NOT QUOTE THE SCORE in your reason. Please mention specific information from #{parameters} in your reason, but be very concise with it!

    Evaluation Steps:
    #{steps_formatted}

    #{test_case_content}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "score" and "reason" key. No words or explanation is needed.

    Example JSON:
    {
        "reason": "The text does not follow the evaluation steps provided.",
        "score": 0
    }
    **

    JSON:
    """
  end

  @doc """
  Formats evaluation steps as a numbered list.
  """
  def format_evaluation_steps(steps) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {step, i} -> "#{i}. #{step}" end)
  end

  def format_evaluation_steps(steps) when is_binary(steps), do: steps

  @doc """
  Formats test case content for the prompt.
  """
  def format_test_case_content(test_case, params) do
    Enum.map_join(params, "\n\n", fn param ->
      value = Map.get(test_case, param)
      formatted_value = format_value(value)
      "#{format_param_name(param)}:\n#{formatted_value}"
    end)
  end

  @doc """
  Formats parameters list as a human-readable string.
  """
  def format_params(params) when is_list(params) do
    Enum.map_join(params, ", ", &format_param_name/1)
  end

  defp format_param_name(:input), do: "Input"
  defp format_param_name(:actual_output), do: "Actual Output"
  defp format_param_name(:expected_output), do: "Expected Output"
  defp format_param_name(:retrieval_context), do: "Retrieval Context"
  defp format_param_name(:context), do: "Context"
  defp format_param_name(param), do: param |> to_string() |> String.capitalize()

  defp format_value(nil), do: "(not provided)"
  defp format_value(value) when is_list(value), do: Enum.join(value, "\n---\n")
  defp format_value(value), do: to_string(value)
end
