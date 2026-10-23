# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/task_completion/templates/*.txt), Copyright Confident
# AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TaskCompletion do
  @moduledoc """
  Prompt templates for the TaskCompletion metric.

  TaskCompletion extracts the task an agent was given and the outcome it
  reached, from its trace or from the test case, then judges how well the
  outcome achieves the task.

  Each function renders deepeval 4.3.1's `TaskCompletionMetric` template
  of the same name byte for byte. The trace is printed as the metric
  prints it, `serialize_to_json(trace_dict, indent=2)`
  (`DeepEvalEx.Tracing.NestedDict.to_json/2`), and the tools called as
  deepeval's `print_tools_called`
  (`DeepEvalEx.Prompts.ToolCorrectness.format_tools/1`).

  `system_one_score/0` and `system_one_questions/1` are its System One
  templates, `_experimental_system_one_score` and
  `_experimental_system_one_questions`.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      extract_goal_and_outcome: 1,
      extract_task_and_outcome_from_trace: 1,
      generate_verdict: 1,
      system_one_score: 0,
      system_one_questions: 1
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract the task and its outcome from a test case
  without a trace: its input, its tools called and its output.

  ## Options

  - `:input` - the test case's input (required)
  - `:actual_output` - the test case's actual output (required)
  - `:tools_called_formatted` - the tools called, as deepeval's
    `print_tools_called` prints them (`""` for none) (required)
  """
  def extract_goal_and_outcome(opts) do
    input = Keyword.fetch!(opts, :input)
    actual_output = Keyword.fetch!(opts, :actual_output)
    tools_called_formatted = Keyword.fetch!(opts, :tools_called_formatted)

    """
    Given an agentic workflow comprised of a human input, AI response, and tools used by the AI, identify the task (or objective the user wants to achieve) and the task_outcome (the final outcome or result of the workflow).
    The task outcome should be solely factual, derived strictly from the workflow (input, response, and tools called), without any reasoning involved.

    ``Example:
    Example input: Can you help me plan a trip to New York this weekend, including travel, accommodation, and sightseeing?
    Example tools called:
    [
      {
        "name": "flight_search",
        "description": "Search for flights based on destination and date.",
        "reasoning": "The input specifies travel as part of the task. This tool is needed to find flight options based on the user's destination and dates.",
        "output": {
          "flights": ["Flight A", "Flight B"]
        },
        "input_parameters": {
          "destination": "New York",
          "date": "Saturday",
          "return_date": "Sunday"
        }
      },
      {
        "name": "hotel_search",
        "description": "Search for hotels in the given location.",
        "reasoning": "The input specifies accommodation as part of the task. This tool is needed to find hotel options in the specified location for the provided dates.",
        "output": {
          "hotels": ["Grand NY Hotel", "Empire Suites"]
        },
        "input_parameters": {
          "location": "New York",
          "check_in": "Saturday",
          "check_out": "Sunday"
        }
      },
      {
        "name": "sightseeing_search",
        "description": "Provide sightseeing options for a given location.",
        "reasoning": "The input specifies sightseeing as part of the task. This tool is needed to generate a list of recommended places to visit in New York.",
        "output": {
          "sights": ["Central Park", "Statue of Liberty", "Times Square"]
        },
        "input_parameters": {
          "location": "New York"
        }
      }
    ]
    Example response: Sure! Flights available to New York include Flight A and Flight B. Accommodation options include Grand NY Hotel and Empire Suites. Suggested sightseeing spots in New York are Central Park, Statue of Liberty, and Times Square. 

    Example JSON:
    {
      "task": "Have the system plan a weekend trip to New York, including travel, accommodation, and sightseeing.",
      "outcome": "The system provided suggested flights departing on Saturday and returning on Sunday, identified hotels with check-in on Saturday and check-out on Sunday, and generated a list of sightseeing destinations in New York City."
    }
    ===== END OF EXAMPLE ======

    **
    IMPORTANT: Please make sure to only return in JSON format with two keys: `task` and `outcome`.
    **

    input: #{input}
    tools called:
    #{tools_called_formatted}
    response: #{actual_output}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to extract the task and its outcome from a nested
  trace dict.

  ## Options

  - `:trace_json` - the nested trace dict, as
    `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it (required)
  """
  def extract_task_and_outcome_from_trace(opts) do
    trace_json = Keyword.fetch!(opts, :trace_json)

    """
    Given a nested workflow trace whose spans may be of type `agent`, `tool`, `llm`, `retriever`, or `custom`, identify:

    1. **task** – the task or objective expressed by the user in the root agent’s input.  
    2. **outcome** – a strictly factual description of what the system did, based only on the trace.

    The task outcome should be solely factual, derived strictly from the trace.
    Do **not** include subjective language such as “successfully”, “efficiently”, or “well”.  
    Enumerate each relevant action or output the trace shows, in plain language.

    ``Example:
    Example trace:
    {
      "name": "trip_planner",
      "type": "agent",
      "input": {
        "input": "Can you help me plan a business trip to Chicago next week?"
      },
      "output": {
        "summary": "Trip planning initiated."
      },
      "available_tools": ["flight_tool", "hotel_tool"],
      "agent_handoffs": [],
      "children": [
        {
          "name": "flight_tool",
          "type": "tool",
          "input": {
            "inputParameters": {
              "destination": "Chicago",
              "date": "2024-07-10"
            }
          },
          "output": {
            "flights": ["Flight 101", "Flight 202"]
          },
          "description": "Search for flights to a destination",
          "children": []
        },
        {
          "name": "hotel_tool",
          "type": "tool",
          "input": {
            "inputParameters": {
              "location": "Chicago",
              "check_in": "2024-07-10",
              "check_out": "2024-07-12"
            }
          },
          "output": {
            "hotels": ["The Grand Chicago", "Lakeview Inn"]
          },
          "description": "Find hotels for specified dates",
          "children": []
        },
        {
          "name": "agenda_llm",
          "type": "llm",
          "input": {
            "prompt": "Draft a meeting agenda",
            "input": [
              {
                "role": "system",
                "content": "You are an executive assistant."
              },
              {
                "role": "user",
                "content": "Create an agenda for a client strategy meeting."
              }
            ]
          },
          "output": "1. Q2 review\\n2. Client feedback\\n3. Strategy planning",
          "model": "gpt-4",
          "inputTokenCount": 38,
          "outputTokenCount": 21,
          "children": []
        },
        {
          "name": "slide_retriever",
          "type": "retriever",
          "input": {
            "embeddingInput": "presentation.pptx"
          },
          "output": {
            "retrievalContext": ["Slide 1: Revenue", "Slide 2: Client Feedback"]
          },
          "topK": 3,
          "chunkSize": 512,
          "children": []
        },
        {
          "name": "client_embedder",
          "type": "custom",
          "input": {
            "text": "Concerns from enterprise clients"
          },
          "output": [0.1, 0.32, 0.85],
          "children": []
        }
      ]
    }
    Example JSON:
    {
      "task": "Plan a business trip to Chicago, including flights, lodging, meeting agenda, presentation review, and client preparation.",
      "outcome": "The system invoked a tool to retrieve two flight options and another tool to find two hotels for the specified dates. An LLM with model 'gpt-4' generated a three-topic meeting agenda from a system/user prompt. A retriever extracted three slides using the embedding input 'presentation.pptx' with topK=3 and chunk size 512. A custom component generated vector embeddings for a client-related input string."
    }
    ===== END OF EXAMPLE =====

    **
    IMPORTANT – return only valid JSON with two keys: `task` and `outcome`.
    **

    trace:
    #{trace_json}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to judge, from 0 to 1, how well an outcome achieves a
  task.

  ## Options

  - `:task` - the task (required)
  - `:actual_outcome` - the outcome (required)
  """
  def generate_verdict(opts) do
    task = Keyword.fetch!(opts, :task)
    actual_outcome = Keyword.fetch!(opts, :actual_outcome)

    """
    Given the task (desired outcome) and the actual achieved outcome, compare how well the actual outcome aligns with the desired task.

    Please return a JSON with two keys: `verdict` and `reason`.
    - The `verdict` should be a score from 0 to 1, where 1 indicates the actual outcome perfectly achieves the desired task, and 0 indicates it does not achieve the task at all.
    - The `reason` should explain why the given verdict was assigned.

    **
    IMPORTANT: Please make sure to only return in JSON format, with `verdict` as a float between 0 and 1.
    Example:
    Task: Have the system plan a weekend trip to New York, including travel, accommodation, and sightseeing.
    Actual outcome: The system provided suggested flights departing on Saturday and returning on Sunday, identified hotels with check-in on Saturday and check-out on Sunday, and generated a list of sightseeing destinations in New York City.
    Example JSON:
    {
      "verdict": 0.85,
      "reason": "The system suggested flights, accommodation, and sightseeing options but did not fully plan the trip as expected."
    }
    **

    Task:
    #{task}

    Actual outcome:
    #{actual_outcome}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked under the `:hybrid` eval mode,
  deepeval's `_experimental_system_one_score` template: the instructions
  of a Score over four task completion levels, about a state holding the
  `task` and the `outcome` (see `DeepEvalEx.SystemOne.Spec.Score`).
  """
  @spec system_one_score() :: String.t()
  def system_one_score, do: "How well does `outcome` achieve `task`?"

  @doc """
  The questions a System One model answers under the `:system_one` eval
  mode, deepeval's `_experimental_system_one_questions` template: a JSON
  array of a weighted Noul, a Noul and a four-level Score, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads. They ask about the agent
  run in the state's `trace`, or without one about the test case's
  `actual_output` and `tools_called`, and about the state's `task` when
  the metric has its own, else the user's.

  ## Options

  - `:has_trace` - whether the state holds the `trace` (required)
  - `:has_task` - whether the state holds the metric's own `task`
    (required)
  """
  @spec system_one_questions(keyword()) :: String.t()
  def system_one_questions(opts) do
    has_trace = Keyword.fetch!(opts, :has_trace)
    has_task = Keyword.fetch!(opts, :has_task)

    {run_capitalised, run} =
      if has_trace,
        do: {"The agent run in `trace`", "the agent run in `trace`"},
        else:
          {"`actual_output` (with the tools in `tools_called`)",
           "`actual_output` (with the tools in `tools_called`)"}

    goal =
      cond do
        has_task -> "`task`"
        has_trace -> "the user's task (the root span's input in `trace`)"
        true -> "the user's task in `input`"
      end

    noul = Python.tojson("#{run_capitalised} fully accomplishes #{goal}.")

    outcome =
      Python.tojson(
        "The final outcome of #{run} is what #{goal} asks for: not a partial result, " <>
          "a different result, or only a plan to get it."
      )

    question = Python.tojson("How completely does #{run} accomplish #{goal}?")

    """


    [
      {
        "type": "noul",
        "statement": #{noul},
        "weight": 2
      },
      {
        "type": "noul",
        "statement": #{outcome}
      },
      {
        "type": "score",
        "question": #{question},
        "levels": ["Not achieved", "Partly achieved", "Mostly achieved", "Fully achieved"]
      }
    ]\
    """
  end
end
