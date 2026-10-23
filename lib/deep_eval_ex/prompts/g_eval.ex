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

  The `*_trace_*` prompts are those of GEval in trace mode, without
  evaluation params: they judge the agent's nested trace dict, printed as
  deepeval's `serialize_to_json(trace_dict, indent=2)`
  (`DeepEvalEx.Tracing.NestedDict.to_json/2`), instead of test case fields.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_evaluation_steps: 1,
      generate_evaluation_results: 1,
      generate_strict_evaluation_results: 1,
      generate_trace_evaluation_steps: 1,
      generate_trace_evaluation_results: 1,
      generate_strict_trace_evaluation_results: 1
    ]

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
  Generates a prompt to create evaluation steps for judging an agent's
  trace from criteria, deepeval's `generate_trace_evaluation_steps`.

  ## Options

  - `:criteria` - the evaluation criteria (required)
  """
  def generate_trace_evaluation_steps(opts) do
    criteria = Keyword.fetch!(opts, :criteria)

    """
    You will be judging an AI agent by its execution trace rather than by a single input and output. The trace is a nested JSON tree of spans. Each span has a `name`, a `type` (`agent`, `llm`, `tool`, `retriever`, or `custom`), an `input`, an `output`, and `children` (the spans it invoked, in execution order). Agent spans may also list `available_tools` and `agent_handoffs`; tool spans may carry a `description`; retriever spans may carry a `retrievalContext`. The root span's input is what the agent was asked to do, and its output is what it finally returned.

    Given the evaluation criteria below, generate 3-4 concise evaluation steps for judging the trace. The steps MUST:
    - Say which parts of the trace are evidence for the criteria (e.g. specific span types, tool arguments, retrieved content, intermediate LLM outputs, the root output).
    - Say how intermediate steps should be judged in relation to one another and to the final root output, not just the final output on its own.
    - Stay grounded in what a trace can show; do not ask for information that is not recorded in spans.


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
  Generates a prompt to score an agent's trace using the evaluation
  steps and optional rubric, deepeval's
  `generate_trace_evaluation_results`.

  ## Options

  - `:evaluation_steps` - the steps, a list or as `format_evaluation_steps/1`
    (required)
  - `:trace_json` - the nested trace dict, as
    `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it (required)
  - `:rubric` - as `format_rubric/1`, or `nil` (default: `nil`)
  - `:score_range` - `{min, max}` (default: `{0, 10}`)
  """
  def generate_trace_evaluation_results(opts) do
    evaluation_steps = opts |> Keyword.fetch!(:evaluation_steps) |> format_evaluation_steps()
    trace_json = Keyword.fetch!(opts, :trace_json)
    rubric = Keyword.get(opts, :rubric)
    {score_min, score_max} = Keyword.get(opts, :score_range, {0, 10})

    {dependencies, score_explanation, reasoning_expectation, rubric_section} =
      if rubric do
        {"evaluation steps and rubric", "based on the rubric provided",
         "Be specific and grounded in the evaluation steps and rubric.", "Rubric:\n#{rubric}\n\n"}
      else
        {"evaluation steps",
         "with #{score_max} indicating the trajectory strongly aligns with the evaluation steps and #{score_min} indicating no alignment",
         "Be specific and grounded in the evaluation steps.", ""}
      end

    """
    You are an evaluator judging an AI agent by its execution trace. Given the following #{dependencies}, assess the trace below and return a JSON object with two fields:

    - `"score"`: an integer between #{score_min} and #{score_max}, #{score_explanation}.
    - `"reason"`: a brief explanation for why the score was given. Do **not** quote the score itself in the explanation.

    #{trace_reading_rules()}

    Your explanation should:
    - #{reasoning_expectation}
    - Cite the specific spans, by `name`, that drove the score.
    - Be concise, clear, and focused on the evaluation logic.


    Only return valid JSON. Do **not** include any extra commentary or text.

    ===== EXAMPLE =====
    Evaluation Steps:
    1. Check whether the agent called a tool that can answer the user's question.
    2. Check whether the tool was given arguments that match the user's request.
    3. Check whether the final output is consistent with what the tool returned.

    Trace:
    {
      "name": "support_agent",
      "type": "agent",
      "input": {"input": "Where is my order #1234?"},
      "output": "Your order #1234 was delivered yesterday.",
      "available_tools": ["order_lookup", "refund_tool"],
      "children": [
        {
          "name": "order_lookup",
          "type": "tool",
          "input": {"order_id": "1234"},
          "output": {"status": "in_transit", "eta": "tomorrow"},
          "children": []
        }
      ]
    }

    Example JSON:
    {
      "reason": "support_agent correctly chose order_lookup and passed the right order_id, but its final output says the order was delivered while order_lookup returned status 'in_transit' with an ETA of tomorrow, so the answer contradicts the tool result.",
      "score": #{score_min}
    }
    ===== END OF EXAMPLE =====

    ---

    Evaluation Steps:
    #{evaluation_steps}

    #{rubric_section}Trace:
    #{trace_json}


    ---
    **Example JSON:**
    {
      "reason": "your concise and informative reason here, citing span names",
      "score": #{score_min}
    }

    JSON:\
    """
  end

  @doc """
  Generates a prompt for strict (binary) evaluation of an agent's trace,
  deepeval's `generate_strict_trace_evaluation_results`.

  ## Options

  - `:evaluation_steps` - the steps, a list or as `format_evaluation_steps/1`
    (required)
  - `:trace_json` - the nested trace dict, as
    `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it (required)
  """
  def generate_strict_trace_evaluation_results(opts) do
    evaluation_steps = opts |> Keyword.fetch!(:evaluation_steps) |> format_evaluation_steps()
    trace_json = Keyword.fetch!(opts, :trace_json)

    """
    You are an evaluator judging an AI agent by its execution trace. Given the evaluation steps, return a JSON with two keys: 1) a `score` key that is STRICTLY EITHER 1 (the trajectory follows the criteria 100% outlined in the evaluation steps), OR 0 (it does not), and 2) a `reason` key, a reason for the given score, but DO NOT QUOTE THE SCORE in your reason.

    #{trace_reading_rules()}

    In your reason, cite the specific spans, by `name`, that decided the score, but be very concise with it!


    Evaluation Steps:
    #{evaluation_steps}

    Trace:
    #{trace_json}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "score" and "reason" key. No words or explanation is needed.

    Example JSON:
    {
      "reason": "support_agent's final output contradicts the status returned by order_lookup.",
      "score": 0
    }
    **

    JSON:\
    """
  end

  # The "How to read the trace" and "How to judge" sections both trace
  # results templates share.
  defp trace_reading_rules do
    """
    How to read the trace:
    - It is a nested JSON tree of spans. Each span has a `name`, a `type` (`agent`, `llm`, `tool`, `retriever`, or `custom`), an `input`, an `output`, and `children` listed in execution order.
    - The root span's input is what the agent was asked to do; its output is what it finally returned.

    How to judge:
    - Judge the whole trajectory, not only the root output. Walk the span tree in order.
    - Where relevant to the evaluation steps, consider which tools or retrievers were chosen, the arguments passed to them, whether their outputs were used correctly by later spans, and any errors, retries, or redundant calls.
    - Base every judgement only on what the trace shows. Do not assume steps happened if no span records them.
    - Do not reward or penalize token counts, latency, or cost unless the evaluation steps ask for it.\
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
