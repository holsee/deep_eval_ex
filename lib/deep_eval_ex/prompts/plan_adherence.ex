# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/plan_adherence/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.PlanAdherence do
  @moduledoc """
  Prompt templates for the PlanAdherence metric, and the plan extraction
  PlanQuality borrows.

  PlanAdherence extracts the user's task (with
  `DeepEvalEx.Prompts.StepEfficiency.extract_task_from_trace/1`) and the
  plan the agent stated from its trace, then scores how strictly the
  agent's actions followed that plan.

  Each function renders deepeval 4.3.1's `PlanAdherenceMetric` template of
  the same name byte for byte. The trace is printed as the metric prints
  it, `serialize_to_json(trace_dict, indent=2)`
  (`DeepEvalEx.Tracing.NestedDict.to_json/2`), `null` without one, and the
  plan one step per line. deepeval's templates always hold the multimodal
  input rules, for any test case, so these do too: the `:multimodal`
  option changes nothing.

  deepeval renders `extract_plan_from_trace` and `evaluate_adherence` with
  an explicit `template_class`, which bypasses a user's
  `evaluation_template`, so only the System One templates,
  `system_one_score/0` and `system_one_questions/1` (deepeval's
  `_experimental_system_one_score` and `_experimental_system_one_questions`),
  can be overridden (see `DeepEvalEx.Prompts.EvaluationTemplate`).
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      system_one_score: 0,
      system_one_questions: 1
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract the plan the agent stated, or clearly
  implied, from a nested trace dict. PlanQuality borrows it.

  ## Options

  - `:trace_json_str` - the nested trace dict, as
    `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it (required)
  - `:multimodal` - accepted as deepeval's template takes it; the
    multimodal input rules are always printed
  """
  @spec extract_plan_from_trace(keyword()) :: String.t()
  def extract_plan_from_trace(opts) do
    trace_json_str = Keyword.fetch!(opts, :trace_json_str)

    """
    You are a **systems analyst** evaluating an AI agent's execution trace.

    Your sole task is to extract the **explicit or clearly implied plan** the agent followed or intended to follow — *only if that plan is directly evidenced in the trace*.

    STRICT RULES TO FOLLOW:

    1. Source Evidence Requirement
    - Every plan step you include **must** be directly supported by explicit text in the trace.  
    - Acceptable evidence sources:
    - `"reasoning"` or `"thought"` fields inside tool calls or function invocations.
    - Explicit plan-like statements or lists written by the agent (e.g., “My plan is to…”).
    - If no evidence exists for a step, DO NOT infer or invent it.

    2. No Hallucination Policy 
    - You must *not* create or rephrase steps that aren't explicitly or strongly implied by the trace.  
    - If there is no coherent plan present, output an empty list.

    3. Focus on Intent, Not Outcomes
    - If the agent's plan is stated but execution differs, still extract the intended steps — but only if those intended steps are traceable.

    4. Granularity
    - Each step should represent a single distinct action or intention.
    - Avoid merging multiple intentions into one step or splitting one intention into multiple steps.

    5. Neutral Language
    - Reproduce the plan steps in **neutral, minimal paraphrasing**.  
    - Do not interpret motivation, quality, or success of actions.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    OUTPUT FORMAT:

    Return a JSON object with exactly this structure:
    {
      "plan": [
        "step 1",
        "step 2",
        ...
      ]
    }

    If no plan is evidenced in the trace, return:
    {
      "plan": []
    }

    Do not include commentary, confidence scores, or explanations.

    TRACE:

    #{trace_json_str}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to score, from `0.0` to `1.0`, how strictly the
  agent's actions in its trace followed its plan.

  ## Options

  - `:user_task` - the task extracted from the trace (required)
  - `:agent_plan` - the extracted plan, its steps joined with newlines
    (required)
  - `:execution_trace_json` - the nested trace dict, as
    `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it (required)
  - `:multimodal` - accepted as deepeval's template takes it; the
    multimodal input rules are always printed
  """
  @spec evaluate_adherence(keyword()) :: String.t()
  def evaluate_adherence(opts) do
    user_task = Keyword.fetch!(opts, :user_task)
    agent_plan = Keyword.fetch!(opts, :agent_plan)
    execution_trace_json = Keyword.fetch!(opts, :execution_trace_json)

    """
    You are an **adversarial plan adherence evaluator**. Your goal is to assign the **lowest justifiable score** based on how strictly the agent's actions in the execution trace align with its declared plan.

    INPUTS:

    - **User Task:** The original request or objective.
    - **Agent Plan:** The explicit step-by-step plan the agent was supposed to follow.
    - **Execution Trace:** A detailed record of all agent actions, reasoning, tool calls, and outputs.

    EVALUATION OBJECTIVE:

    Determine whether the agent **exactly and exclusively** followed its plan.  
    You are not evaluating success, correctness, or usefulness — **only plan obedience**.

    Assume **non-adherence by default** unless clear, direct evidence in the trace proves that 
    each planned step was executed *as written* and *no additional actions occurred*.

    ### STRICT ADHERENCE RULES

    1. Step Verification
    - Every step in the plan must correspond to a **verifiable, explicit** action or reasoning entry in the trace.
    - Each step must appear in the same logical order as the plan.
    - If a step is missing, only implied, or ambiguous, treat as **not followed**.

    2. No Extraneous Actions
    - If the trace includes **any** major action, tool call, or reasoning segment not clearly present in the plan, immediately lower the score to as low as possible.
    - Extra or unnecessary steps are considered serious violations.

    3. Order Consistency
    - If the agent performed steps in a different order than the plan specifies, the score must be close to 0, regardless of other alignment.

    4. Completeness
    - If even one planned step is missing, skipped, or only partially reflected in the trace, the score must be lowest possible.

    5. Ambiguity Handling
    - If it is unclear whether a trace action corresponds to a plan step, treat that step as **not executed**.
    - When uncertain, assign the **lower score**.

    6. Focus Exclusively on Plan Compliance
    - Ignore task success, reasoning quality, or correctness of outcomes. 
    - Evaluate *only* whether the trace reflects the exact plan execution.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.



    SCORING SCALE

    - **1.0 — Perfect adherence**
    - Every planned step is explicitly and verifiably present in the trace, in correct order.
    - No skipped or added steps.
    - No ambiguity in matching.

    - **0.75 — Strong adherence**
    - All or nearly all steps are executed in order.
    - At most one minor deviation (e.g., a trivial reordering or minor redundant step) that does not change the plan’s structure.

    - **0.5 — Partial adherence**
    - Some steps clearly match, but others are missing, out of order, or replaced.
    - At least one extra or ambiguous action appears.
    - *This should be the highest score possible when there are any deviations.*

    - **0.25 — Weak adherence**
    - Only a few steps from the plan appear in the trace, or multiple extraneous actions occur.
    - The structure or sequence of the plan is mostly lost.

    - **0.0 — No adherence**
    - The trace shows little or no resemblance to the plan.
    - Steps are ignored, replaced, or executed in an entirely different order.

    Always err toward the **lower score** when evidence is partial, ambiguous, or contradictory.

    OUTPUT FORMAT:

    Return a JSON object with exactly this structure:

    {
      "score": 0.0,
      "reason": "1-3 concise, factual sentences citing specific matched, missing, or extra steps."
    }

    Requirements for `"reason"`:
    - Reference specific plan step numbers or phrases.
    - Mention concrete trace evidence of mismatches or additions.
    - Avoid subjective adjectives (e.g., “mostly”, “close”, “reasonable”).
    - Be precise and neutral.

    ---

    INPUTS:

    User Task:
    #{user_task}

    Agent Plan:
    #{agent_plan}

    Execution Trace:
    #{execution_trace_json}

    ---

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked under the `:hybrid` eval mode,
  deepeval's `_experimental_system_one_score` template: the instructions
  of a Score over five adherence levels, about a state holding the `task`,
  the `plan` and the compacted `trace` (see `DeepEvalEx.SystemOne.Spec.Score`).
  """
  @spec system_one_score() :: String.t()
  def system_one_score do
    "How strictly do the actions in `trace` follow `plan`, the plan the agent declared for " <>
      "`task`? Every planned step must appear in `trace` in the same order, and any major " <>
      "action not in `plan` counts against it. Judge only obedience to `plan`, not whether " <>
      "the task succeeded."
  end

  @doc """
  The questions a System One model answers under the `:system_one` eval
  mode, deepeval's `_experimental_system_one_questions` template: a JSON
  array of a weighted Choice, a Choice and a five-level Choice, each with
  the not-applicable option "The agent states no plan", which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads. They ask about the agent
  run in the state's `trace`, or without one about the test case's
  `actual_output` and `tools_called`.

  ## Options

  - `:has_trace` - whether the state holds the `trace` (required)
  """
  @spec system_one_questions(keyword()) :: String.t()
  def system_one_questions(opts) do
    {run, source} =
      if Keyword.fetch!(opts, :has_trace),
        do:
          {"the agent run in `trace`", "`trace` (in its reasoning, thoughts or an explicit plan)"},
        else: {"`actual_output` (with the tools in `tools_called`)", "`actual_output`"}

    every_step =
      Python.tojson(
        "Does #{run} carry out every step of the plan the agent states in #{source}, " <>
          "explicitly and in the stated order?"
      )

    outside =
      Python.tojson(
        "Does #{run} take any major action, tool call or reasoning step that is not part " <>
          "of the plan the agent states in #{source}?"
      )

    question =
      Python.tojson(
        "How strictly do the actions of #{run} follow the plan the agent states in #{source}?"
      )

    no_plan = Python.tojson("The agent states no plan")

    """


    [
      {
        "type": "choice",
        "question": #{every_step},
        "options": {"Yes, every planned step is carried out in order": 1.0, "No, a planned step is missing, only implied or out of order": 0.0, #{no_plan}: null},
        "weight": 2
      },
      {
        "type": "choice",
        "question": #{outside},
        "options": {"No, it does only what the plan says": 1.0, "Yes, it takes actions outside the plan": 0.0, #{no_plan}: null}
      },
      {
        "type": "choice",
        "question": #{question},
        "options": {"No adherence": 0.0, "Weak adherence": 0.25, "Partial adherence": 0.5, "Strong adherence": 0.75, "Perfect adherence": 1.0, #{no_plan}: null}
      }
    ]\
    """
  end
end
