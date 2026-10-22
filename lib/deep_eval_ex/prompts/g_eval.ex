# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/g_eval/templates/*.txt and deepeval/metrics/g_eval/utils.py),
# Copyright Confident AI, Apache-2.0.
# Original: https://github.com/confident-ai/deepeval
#
# test/deep_eval_ex/prompt_golden_test.exs checks every byte of the
# prompts against deepeval's.

defmodule DeepEvalEx.Prompts.GEval do
  @moduledoc """
  Prompt templates for the GEval metric.

  Based on the G-Eval framework: https://arxiv.org/pdf/2303.16634.pdf

  Each prompt function renders deepeval 4.3.1's `GEval` template of the
  same name byte for byte, as deepeval renders it for a test case
  (`multimodal=False`, no `_additional_context`): the multimodal input
  rules fragment is left out, as DeepEvalEx has no multimodal test cases.
  The `format_*` helpers build the template arguments as deepeval's
  `number_evaluation_steps`, `construct_g_eval_params_string`,
  `construct_test_case_string` and `format_rubrics` do.
  """

  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Params.SingleTurn
  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to create evaluation steps from criteria.

  The LLM will generate 3-4 concrete evaluation steps based on the
  provided criteria and parameters.

  ## Options

  - `:criteria` - the evaluation criteria (required)
  - `:parameters` - the evaluated params, as `format_params/1` (required)
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
      "steps": <list_of_strings>
    }
    **

    JSON:\
    """
  end

  @doc """
  Generates a prompt for evaluation using the generated steps.

  This is the main evaluation prompt that scores the test case
  based on the evaluation steps and optional rubric.

  ## Options

  - `:evaluation_steps` - the steps, a list or as `format_evaluation_steps/1`
    (required)
  - `:test_case_content` - as `format_test_case_content/2` (required)
  - `:parameters` - as `format_params/1` (required)
  - `:rubric` - as `format_rubric/1`, or `nil` (default: `nil`)
  - `:score_range` - `{min, max}` (default: `{0, 10}`)
  """
  def generate_evaluation_results(opts) do
    evaluation_steps = opts |> Keyword.fetch!(:evaluation_steps) |> format_evaluation_steps()
    test_case_content = Keyword.fetch!(opts, :test_case_content)
    parameters = Keyword.fetch!(opts, :parameters)
    rubric = Keyword.get(opts, :rubric)
    {score_min, score_max} = Keyword.get(opts, :score_range, {0, 10})

    {dependencies, score_explanation, reasoning_expectation, rubric_section} =
      if rubric do
        {"evaluation steps and rubric", "based on the rubric provided",
         "Be specific and grounded in the evaluation steps and rubric.", "Rubric:\n#{rubric}\n\n"}
      else
        {"evaluation steps",
         "with #{score_max} indicating strong alignment with the evaluation steps and #{score_min} indicating no alignment",
         "Be specific and grounded in the evaluation steps.", ""}
      end

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
    #{evaluation_steps}

    #{rubric_section}Test Case:
    #{test_case_content}

    Parameters:
    #{parameters}


    ---
    **Example JSON:**
    {
      "reason": "your concise and informative reason here",
      "score": #{score_min}
    }

    JSON:\
    """
  end

  @doc """
  Generates a prompt for strict (binary) evaluation.

  Returns either 0 or 1 based on whether the criteria is fully met.

  ## Options

  - `:evaluation_steps` - the steps, a list or as `format_evaluation_steps/1`
    (required)
  - `:test_case_content` - as `format_test_case_content/2` (required)
  - `:parameters` - as `format_params/1` (required)
  """
  def generate_strict_evaluation_results(opts) do
    evaluation_steps = opts |> Keyword.fetch!(:evaluation_steps) |> format_evaluation_steps()
    test_case_content = Keyword.fetch!(opts, :test_case_content)
    parameters = Keyword.fetch!(opts, :parameters)

    """
    Given the evaluation steps, return a JSON with two keys: 1) a `score` key that is STRICTLY EITHER 1 (follows the criteria 100% outlined in the evaluation steps), OR 0 (does not follow the criteria), and 2) a `reason` key, a reason for the given score, but DO NOT QUOTE THE SCORE in your reason. Please mention specific information from #{parameters} in your reason, but be very concise with it!



    Evaluation Steps:
    #{evaluation_steps}

    #{test_case_content}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "score" and "reason" key. No words or explanation is needed.

    Example JSON:
    {
      "reason": "The text does not follow the evaluation steps provided.",
      "score": 0
    }
    **

    JSON:\
    """
  end

  @doc """
  Formats evaluation steps as a numbered list, one step per line, each
  ending with a newline, as deepeval's `number_evaluation_steps`.

  A string is taken as already formatted.

  ## Examples

      iex> DeepEvalEx.Prompts.GEval.format_evaluation_steps(["Read it.", "Score it."])
      "1. Read it.\\n2. Score it.\\n"
  """
  def format_evaluation_steps(steps) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join(fn {step, i} -> "#{i}. #{step}\n" end)
  end

  def format_evaluation_steps(steps) when is_binary(steps), do: steps

  @doc """
  Formats test case content for the prompt, as deepeval's
  `construct_test_case_string`: each param as its name, a newline, then
  its value followed by a space and a blank line.

  Values are printed as Python's `str()` prints them: strings as they are,
  lists (retrieval context, tool calls, ...) as Python lists, `nil` as
  `None`.
  """
  def format_test_case_content(test_case, params) do
    Enum.map_join(params, fn param ->
      "#{format_param_name(param)}:\n#{format_value(Map.get(test_case, param))} \n\n"
    end)
  end

  @doc """
  Formats parameters list as a human-readable string, as deepeval's
  `construct_g_eval_params_string`: `"A"`, `"A and B"`, `"A, B, and C"`.

  Each param is named as deepeval's GEval names it (see
  `DeepEvalEx.Params.SingleTurn.display_name/1`), e.g. `:tools_called` as
  `Tools Called`.

  ## Examples

      iex> DeepEvalEx.Prompts.GEval.format_params([:input, :actual_output, :expected_output])
      "Input, Actual Output, and Expected Output"
  """
  def format_params(params) when is_list(params) do
    case Enum.map(params, &format_param_name/1) do
      [name] -> name
      [first, second] -> "#{first} and #{second}"
      names -> "#{names |> Enum.drop(-1) |> Enum.join(", ")}, and #{List.last(names)}"
    end
  end

  @doc """
  Formats a rubric sorted as `DeepEvalEx.Metrics.GEval.Rubric.validate_and_sort/1`
  sorts it for the prompt, as deepeval's `format_rubrics`: one
  `"<start>-<end>: <expected outcome>"` line per entry, or
  `"<score>: <expected outcome>"` for a single-score range. `nil` stays
  `nil`. See `DeepEvalEx.Metrics.GEval.Rubric.format/1`.

  ## Examples

      iex> alias DeepEvalEx.Metrics.GEval.Rubric
      iex> DeepEvalEx.Prompts.GEval.format_rubric([
      ...>   Rubric.new!(score_range: {0, 4}, expected_outcome: "Wrong."),
      ...>   Rubric.new!(score_range: {10, 10}, expected_outcome: "Correct.")
      ...> ])
      "0-4: Wrong.\\n10: Correct."
  """
  @spec format_rubric([Rubric.t()] | nil) :: String.t() | nil
  defdelegate format_rubric(rubric), to: Rubric, as: :format

  # deepeval's G_EVAL_PARAMS names; params it does not name keep a
  # capitalised field name.
  defp format_param_name(param) do
    SingleTurn.display_name(param) || param |> to_string() |> String.capitalize()
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Python.repr(value)
end
