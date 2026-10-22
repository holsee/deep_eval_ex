# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/argument_correctness/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ArgumentCorrectness do
  @moduledoc """
  Prompt templates for the ArgumentCorrectness metric.

  ArgumentCorrectness measures how many of an agent's tool calls pass input
  parameters that correctly address the input.

  Each function renders deepeval 4.3.1's `ArgumentCorrectnessMetric`
  template of the same name byte for byte, as deepeval renders it for a
  text-only test case: its `generate_verdicts` and `generate_reason`
  templates include the multimodal input rules only for multimodal test
  cases, so these prompts leave them out. The tool calls are printed as
  Python prints a list of deepeval `ToolCall`s, each its `__repr__`, the
  reasons as a Python list and the score as `format(score, ".2f")` (see
  `DeepEvalEx.Prompts.Python`). `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to judge whether the input parameters of each tool
  call correctly address the input.

  For each tool call, the verdict is:
  - "yes" - Its input parameters relevantly and correctly address the input
  - "no" - They do not, or there are none, with a reason

  ## Options

  - `:input` - the input the agent responded to (required)
  - `:tools_called` - the `DeepEvalEx.Schemas.ToolCall`s to judge, printed
    as deepeval's `ToolCall.__repr__` (required)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    tools_called = opts |> Keyword.fetch!(:tools_called) |> Python.repr()

    """

    For the provided list of tool calls, determine whether each tool call input parameter is relevantly and correctly addresses the input.

    Please generate a list of JSON with two keys: `verdict` and `reason`.
    The 'verdict' key should STRICTLY be either a 'yes' or 'no'. Answer 'yes' if the tool call input parameter is relevantly and correctly addresses the original input, 'no' if the tool call input parameter doesn't correctly and relevantly address the original input.
    The 'reason' is the reason for the verdict.
    Provide a 'reason' ONLY if the answer is 'no'. 
    If there is no input parameter, answer 'no' for the verdict and provide the reason as "No input parameter provided".



    **
    IMPORTANT: Please make sure to only return in valid and parseable JSON format, with the 'verdicts' key mapping to a list of JSON objects. Ensure all strings are closed appropriately. Repair any invalid JSON before you output it.
    Example input: 
    "What was the highest temperature recorded in Paris in 2023?"

    Example tool calls: 
    [
      ToolCall(
        name="WeatherHistoryAPI",
        description="Fetches historical weather data for a given city and date range",
        reasoning="I need to check all 2023 temperature records for Paris to find the highest one.",
        input_parameters={
          "city_name": "Paris",
          "country_code": "FR",
          "date_range_start": "2023-01-01",
          "date_range_end": "2023-12-31",
          "data_type": "temperature_max_daily_celsius"
        }
      ),
      ToolCall(
        name="MathAnalyzer",
        description="Performs statistical calculations on numeric datasets",
        reasoning="I will calculate the maximum temperature value from the daily dataset.",
        input_parameters={
          "operation": "max",
          "dataset_source": "WeatherHistoryAPI.daily_max_temperatures",
          "expected_unit": "celsius"
        }
      ),
      ToolCall(
        name="MovieRecommender",
        description="Recommends movies based on user mood or location",
        reasoning="I thought Paris movies might be fun to suggest, but this is unrelated to the question.",
        input_parameters={
          "preferred_genres": ["romance", "comedy"],
          "setting_city": "Paris",
          "language_preference": "French or English"
        }
      )
    ]

    Example JSON:
    {
      "verdicts": [
        {
          "verdict": "yes"
        },
        {
          "verdict": "yes"
        },
        {
          "reason": "Recommending romantic Parisian comedies does not help find the highest temperature in 2023.",
          "verdict": "no"
        }
      ]  
    }
    ===== END OF EXAMPLE ======

    Since you are going to generate a verdict for each statement, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to the number of `statements`.
    **          

    Input:
    #{input}

    Tool Calls:
    #{tools_called}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:incorrect_tool_calls_reasons` - the reasons of the `"no"` verdicts,
    `nil` where the judge gave none (required)
  - `:input` - the input (required)
  - `:score` - the argument correctness score (required)
  """
  def generate_reason(opts) do
    incorrect_tool_calls_reasons =
      opts |> Keyword.fetch!(:incorrect_tool_calls_reasons) |> Python.repr()

    input = Keyword.fetch!(opts, :input)
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)

    """
    Given the argument correctness score, the list of reasons of incorrect tool calls, and the input, provide a CONCISE reason for the score. Explain why it is not higher, but also why it is at its current score. You can mention tool calls or input, but do not mention an output or a response.
    If there is nothing incorrect, just say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).



    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason. Ensure all strings are closed appropriately. Repair any invalid JSON before you output it.

    Example:
    Example JSON:
    {
      "reason": "The score is <argument_correctness_score> because <your_reason>."
    }
    ===== END OF EXAMPLE ======
    **


    Argument Correctness Score:
    #{score}

    Reasons why the score can't be higher based on incorrect tool calls:
    #{incorrect_tool_calls_reasons}

    Input:
    #{input}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each tool call under the
  `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the tool call's
  `__repr__` (see `DeepEvalEx.SystemOne.Spec.Verdicts`). P(yes) is the
  probability that its input parameters correctly address the input.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict,
    do:
      "Do the input parameters of `tool_call` relevantly and correctly address `input`? " <>
        "Answer no if there are no input parameters."

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about `input`
  and the structured `tools_called`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every tool call in `tools_called` has `input_parameters` that correctly address `input`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No tool call in `tools_called` has `input_parameters` that are missing, irrelevant to `input`, or wrong for `input`."
      },
      {
        "type": "score",
        "question": "How many of the tool calls in `tools_called` have `input_parameters` that correctly address `input`?",
        "levels": ["None of them", "Less than half", "Most of them", "All of them"]
      }
    ]\
    """
  end
end
