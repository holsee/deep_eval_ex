# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/tool_correctness/templates/get_tool_selection_score.txt),
# Copyright Confident AI, Apache-2.0.
# Original: https://github.com/confident-ai/deepeval
#
# test/deep_eval_ex/prompt_golden_test.exs checks every byte of the
# prompts against deepeval's.

defmodule DeepEvalEx.Prompts.ToolCorrectness do
  @moduledoc """
  Prompt templates for the ToolCorrectness metric.

  Contains the tool selection evaluation prompt used when
  `available_tools` are provided.

  `get_tool_selection_score/1` renders deepeval 4.3.1's
  `ToolCorrectnessMetric.get_tool_selection_score` template byte for byte,
  with tools formatted by `format_tools/1` as deepeval's
  `print_tools_called` formats them.
  """

  alias DeepEvalEx.TestRun.JSON

  @doc """
  Generates a prompt for the LLM to evaluate tool selection quality.

  ## Options

  - `:user_input` - The user's input/task (required)
  - `:tools_called` - Formatted string of tools called (required)
  - `:available_tools` - Formatted string of available tools (required)
  """
  def get_tool_selection_score(opts) do
    user_input = Keyword.fetch!(opts, :user_input)
    tools_called = Keyword.fetch!(opts, :tools_called)
    available_tools = Keyword.fetch!(opts, :available_tools)

    """
    You are an expert evaluator assessing the **Tool Selection** quality of an AI agent.

    You are given:
    - The **user input** that defines the user's goal / task.
    - A list of **available tools**, each with a name and description.
    - A list of **tool calls made** by the agent during execution, including tool name and parameters.

    Your job is to assign a **Tool Selection score** from 0.0 to 1.0 based on how appropriate and well-matched the agent's chosen tools were to the task's requirements.

    ---

    DEFINITION:

    Tool Selection evaluates how suitable the agent's tool choices were in addressing the task and sub-tasks.

    This metric does **not** consider:
    - How well the tools were used (execution quality)
    - Whether the agent adhered to a plan
    - Whether the output was correct or efficient

    It only assesses whether the **right tools** were selected, based on their stated descriptions and the demands of the task.

    ---

    INSTRUCTIONS:

    Step 1: Read the **user task** to understand what needed to be accomplished.

    Step 2: Examine the **available tools** and their descriptions to understand the intended purpose of each.

    Step 3: Review the **tool calls made by the agent**:
    - Were the selected tools well-aligned with the task?
    - Were any obviously better-suited tools ignored?
    - Were any tools misapplied or used unnecessarily?

    Step 4: Identify selection issues:
    - **Correct Selection**: Tool(s) chosen directly and appropriately matched the subtask.
    - **Over-selection**: More tools were selected than necessary, despite availability of a simpler or more direct option.
    - **Under-selection**: Key tools that were well-suited were omitted.
    - **Mis-selection**: Tools were chosen that were poorly matched to their purpose or the subtask.

    ---

    SCORING GUIDE:

    - **1.0** → All selected tools were appropriate and necessary. No better-suited tools were omitted.
    - **0.75** → Tool choices were mostly appropriate, with minor omissions or unnecessary use.
    - **0.5** → Mixed tool selection. Some useful tools ignored or some inappropriate ones used.
    - **0.25** → Poor tool selection. Better alternatives were available and ignored.
    - **0.0** → Tool selection was clearly misaligned with task requirements.

    ---

    OUTPUT FORMAT:

    Return a valid JSON object with this exact structure:
    {
      "score": float between 0.0 and 1.0,
      "reason": "1-3 concise, factual sentences explaining the score. Reference specific tool names and descriptions when relevant."
    }

    Do not include any additional commentary or output outside the JSON object.

    ---

    USER INPUT:
    #{user_input}

    ALL AVAILABLE TOOLS:
    #{available_tools}

    TOOL CALLS MADE BY AGENT:
    #{tools_called}

    JSON:\
    """
  end

  @doc """
  Formats a list of ToolCall structs for prompt inclusion, as deepeval's
  `print_tools_called` does.

  Each tool call is its `json.dumps(indent=4)` (`name`, `type`,
  `description`, `reasoning`, `output` and `input_parameters`, `null` when
  unset, non-ASCII escaped) indented by two spaces, inside `[` and `]`. An
  empty list formats as the empty string.
  """
  def format_tools([]), do: ""

  def format_tools(tools) when is_list(tools) do
    formatted =
      Enum.map_join(tools, ",\n", fn tool ->
        tool
        |> tool_json()
        |> JSON.encode!(indent: 4)
        |> String.split("\n")
        |> Enum.map_join("\n", &("  " <> &1))
      end)

    "[\n#{formatted}\n]"
  end

  # deepeval serialises ToolCall's fields in this order, its type as the
  # enum value.
  defp tool_json(tool) do
    Jason.OrderedObject.new([
      {"name", tool.name},
      {"type", tool.type |> to_string() |> String.upcase()},
      {"description", tool.description},
      {"reasoning", tool.reasoning},
      {"output", tool.output},
      {"input_parameters", tool.input_parameters}
    ])
  end
end
