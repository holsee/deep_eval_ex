# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/tool_use/templates/*.txt), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ToolUse do
  @moduledoc """
  Prompt templates for the ToolUse metric.

  ToolUse measures, for each unit interaction of a conversation, how well
  the assistant chose its tools from the available ones and how correct
  the arguments it called them with were.

  Each function renders deepeval 4.3.1's `ToolUseMetric` template of the
  same name byte for byte. None of them prints the multimodal input rules,
  so they take no `:multimodal` option. The messages and tools are printed
  as the metric passes them, and the final score and threshold as Python's
  `str()` of them, unformatted (see `DeepEvalEx.Prompts.Python`).

  As in deepeval, the metric explains both of its scores with
  `get_tool_selection_final_reason/1`; `get_tool_argument_final_reason/1`
  is rendered by no deepeval code path but is part of its template class,
  so it can be overridden all the same.

  `system_one_tool_selection_score/0`,
  `system_one_argument_correctness_score/0` and `system_one_questions/0` are
  its System One templates, `_experimental_system_one_tool_selection_score`,
  `_experimental_system_one_argument_correctness_score` and
  `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      get_tool_selection_score: 1,
      get_argument_correctness_score: 1,
      get_tool_selection_final_reason: 1,
      get_tool_argument_final_reason: 1,
      system_one_tool_selection_score: 0,
      system_one_argument_correctness_score: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to score the tools the assistant chose in one unit
  interaction.

  ## Options

  - `:user_input` - the unit's user messages, each followed by `" \\n"`
    (required)
  - `:assistant_messages` - the unit's assistant messages, likewise
    (required)
  - `:tools_called` - the tools the assistant called, each one's
    `ToolCall.__repr__` joined with commas (required)
  - `:available_tools` - the available tools, likewise (required)
  """
  def get_tool_selection_score(opts) do
    user_input = Keyword.fetch!(opts, :user_input)
    assistant_messages = Keyword.fetch!(opts, :assistant_messages)
    tools_called = Keyword.fetch!(opts, :tools_called)
    available_tools = Keyword.fetch!(opts, :available_tools)

    """
    You are an expert evaluator assessing the **Tool Selection Quality** of an AI agent.

    OBJECTIVE
    Evaluate whether the agent **selected the most appropriate tools** for completing the user's task, given a list of available tools.

    This metric focuses **only** on which tools were chosen — **not** how they were used or whether they succeeded.

    EVALUATION RULES

    1. Relevance
    - Each tool used must directly support the user's stated goal or a clear sub-task derived from it.
    - Tools unrelated to the goal lower the score sharply.

    2. Appropriateness
    - The chosen tools must match their described purpose.
    - If a more suitable tool existed and was ignored, score ≤ 0.5.

    3. Necessity
    - Every tool call must be justified by clear need.
    - Redundant or speculative tool use (e.g., calling multiple tools that overlap) reduces the score.

    4. Strictness
    - When uncertain if a tool was required or correctly chosen, assume it was **not** appropriate.
    - Only perfect alignment between the task and tool choice earns a high score.

    SCORING GUIDE:

    - **1.0** → Every tool used was necessary and perfectly matched to the task; no better alternative ignored.  
    - **0.75** → Tool selection was mostly correct, with only minor redundancy or a small omission.  
    - **0.5** → Mixed quality; some appropriate selections, but others questionable or missing.  
    - **0.25** → Poor selection; major mismatches or misuse of available tools.  
    - **0.0** → Tool selection irrelevant, random, or unjustified.

    OUTPUT FORMAT:

    Return a JSON object with:

    {
      "score": float between 0.0 and 1.0,
      "reason": "1-3 factual sentences explaining which tools were appropriate or inappropriate for the task, referencing specific tool names."
    }

    USER INPUT:
    #{user_input}

    ASSISTANT MESSAGES:
    #{assistant_messages}

    TOOLS CALLED:
    #{tools_called}

    AVAILABLE TOOLS:
    #{available_tools}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to score the arguments of the tools the assistant
  called in one unit interaction.

  ## Options

  As for `get_tool_selection_score/1`.
  """
  def get_argument_correctness_score(opts) do
    user_input = Keyword.fetch!(opts, :user_input)
    assistant_messages = Keyword.fetch!(opts, :assistant_messages)
    tools_called = Keyword.fetch!(opts, :tools_called)
    available_tools = Keyword.fetch!(opts, :available_tools)

    """
    You are an expert evaluator assessing the **Tool Argument Quality** of an AI agent.

    OBJECTIVE:

    Evaluate whether the **arguments and parameters** passed to each tool were:
    - Correctly structured and complete.
    - Contextually appropriate for the user's goal.
    - Compatible with each tool's intended purpose.

    This metric focuses **only** on argument-level correctness and relevance — not which tools were chosen.

    EVALUATION RULES

    1. Relevance
    - Each argument must align with the task and the tool's documented input fields.
    - Unrelated, empty, or default arguments reduce the score sharply.

    2. **Completeness**
    - All required parameters must be provided.
    - Missing or malformed arguments (e.g., wrong data types or incomplete context) lower the score.

    3. **Specificity**
    - Arguments should reflect task-specific values, not generic placeholders.
    - Overly vague or default arguments are penalized.

    4. **Justification**
    - Each argument must make sense in context.
    - If it doesn't clearly derive from the user's request, assume it's incorrect.

    5. **Strict Bias**
    - When uncertain whether arguments fit the tool or task, assume they were **incorrect**.

    SCORING GUIDE:

    - **1.0** → All arguments are accurate, specific, and fully aligned with both the task and tool requirements.  
    - **0.75** → Mostly correct; minor omissions or small mismatches.  
    - **0.5** → Partial correctness; some valid parameters, but key ones missing or off-target.  
    - **0.25** → Poor argument quality; several invalid or irrelevant fields.  
    - **0.0** → Arguments nonsensical, generic, or unrelated to task/tool intent.

    OUTPUT FORMAT:

    Return a JSON object with:
    {
      "score": float between 0.0 and 1.0,
      "reason": "1-3 sentences explaining argument alignment or issues, referencing specific parameter names or values when possible."
    }

    ---

    USER INPUT:
    #{user_input}

    ASSISTANT MESSAGES:
    #{assistant_messages}

    TOOLS CALLED (with arguments):
    #{tools_called}

    AVAILABLE TOOLS:
    #{available_tools}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the tool selection scores, and, as deepeval
  uses it for both, the argument correctness scores.

  ## Options

  - `:all_scores_and_reasons` - each score and reason,
    `"\\nScore: <score> \\nReason: <reason> \\n"`, concatenated (required)
  - `:final_score` - the metric's score, printed as Python's `str()`
    (required)
  - `:threshold` - the metric's threshold, likewise (required)
  """
  def get_tool_selection_final_reason(opts) do
    all_scores_and_reasons = Keyword.fetch!(opts, :all_scores_and_reasons)
    final_score = Keyword.fetch!(opts, :final_score)
    threshold = Keyword.fetch!(opts, :threshold)

    """
    You are an expert evaluator summarizing the outcome of a **Tool Selection** evaluation.

    You are given:
    - A list of **tool selection sub-scores and reasons**, each describing how appropriately the agent chose tools for its task.
    - The **final aggregated score** across all sub-evaluations.
    - A **threshold** representing the minimum passing score.

    Your task is to write a **single concise explanation (1-3 sentences)** that captures:
    - Why the agent **passed or failed** based on tool choice quality.
    - The key patterns or trends in the sub-reasons (e.g., consistent correct choices, repeated irrelevant tool calls, missed best-fit tools).
    - A clear statement linking the **score** and **threshold** outcome (e.g., “The agent passed because…” or “Failed because…”).

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <score> because <your_reason>."
    }

    RULES:
    - Focus on *which tools were selected* and *why that selection pattern was or wasn't appropriate*.
    - Mention specific issues or strengths like redundancy, misuse, or perfect matching.
    - Avoid vague or subjective language such as “pretty good” or “reasonable”.
    - Do **not** reference argument-level details; this summary is only for tool choice quality.
    - The result must read as a self-contained, factual justification.

    FORMAT:
    Return only a single plain-text string. Do **not** include JSON or other formatting.

    All Tool Selection Sub-Scores and Reasons:
    #{all_scores_and_reasons}

    Final Score: #{Python.repr(final_score)}
    Threshold: #{Python.repr(threshold)}
    Result: #{result(final_score, threshold)}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the argument correctness scores, deepeval's
  `get_tool_argument_final_reason`, which its metric never renders (see the
  moduledoc).

  ## Options

  As for `get_tool_selection_final_reason/1`.
  """
  def get_tool_argument_final_reason(opts) do
    all_scores_and_reasons = Keyword.fetch!(opts, :all_scores_and_reasons)
    final_score = Keyword.fetch!(opts, :final_score)
    threshold = Keyword.fetch!(opts, :threshold)

    """
    You are an expert evaluator summarizing the outcome of a **Tool Argument Quality** evaluation.

    You are given:
    - A list of **argument-level sub-scores and reasons**, each evaluating whether the arguments passed to tools were accurate, complete, and contextually appropriate.
    - The **final aggregated score** across all argument evaluations.
    - A **threshold** representing the minimum passing score.

    Your task is to write a **single concise explanation (1-3 sentences)** that clearly states:
    - Why the agent **passed or failed** in its use of tool arguments.
    - The dominant strengths or weaknesses from the sub-reasons (e.g., correct parameterization, missing required fields, generic values, or misaligned arguments).
    - Whether the agent met or fell short of the threshold and why.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <score> because <your_reason>."
    }

    RULES:
    - Focus strictly on **argument correctness** and **context alignment** — not which tools were chosen.
    - Reference specific argument-level problems or successes where helpful.
    - Keep language objective and factual; avoid speculation or vague phrasing.
    - The summary must stand alone as a clear explanation of the final result.

    FORMAT:
    Return only a single plain-text string. Do **not** include JSON or any extra formatting.

    All Tool Argument Sub-Scores and Reasons:
    #{all_scores_and_reasons}

    Final Score: #{Python.repr(final_score)}
    Threshold: #{Python.repr(threshold)}
    Result: #{result(final_score, threshold)}

    JSON:\
    """
  end

  # Jinja's `{% if final_score|float >= threshold|float %}PASS{% else %}FAIL{% endif %}`.
  defp result(final_score, threshold), do: if(final_score >= threshold, do: "PASS", else: "FAIL")

  @doc """
  The question a System One model is asked about each unit interaction's
  tool selection under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_tool_selection_score` template: the
  instructions of a Score over five tool selection levels, about a state
  holding the `user_messages`, `assistant_messages`, `tools_called` and
  `available_tools` (see `DeepEvalEx.SystemOne.Spec.Score`).
  """
  @spec system_one_tool_selection_score() :: String.t()
  def system_one_tool_selection_score do
    """
    How well do the tools in `tools_called`, which the assistant called while writing `assistant_messages`, match what `user_messages` asked for, given the tools in `available_tools`? Unnecessary, redundant or unrelated calls, and a better-suited available tool that was ignored, count against it.\
    """
  end

  @doc """
  The question a System One model is asked about the arguments of each unit
  interaction's tool calls under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_argument_correctness_score` template: the
  instructions of a Score over five argument correctness levels, about the
  same state as `system_one_tool_selection_score/0`.
  """
  @spec system_one_argument_correctness_score() :: String.t()
  def system_one_argument_correctness_score do
    """
    How correct are the arguments of the tool calls in `tools_called`, for what `user_messages` asked and for each tool's definition in `available_tools`? Missing, malformed, generic or unrelated arguments count against it.\
    """
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  about the `turns` and the `available_tools`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "In every assistant turn of `turns`, the tools in `tools_called` are the most suitable of `available_tools` for what the user asked: no call is unnecessary, redundant or unrelated to the user's goal, and no better-suited tool in `available_tools` was ignored when one was needed."
      },
      {
        "type": "noul",
        "statement": "Every tool call in the `tools_called` of the assistant turns in `turns` passes arguments that are correct, specific and complete for what the user asked and for that tool's definition in `available_tools`, with no missing, malformed, generic or unrelated argument."
      }
    ]\
    """
  end
end
