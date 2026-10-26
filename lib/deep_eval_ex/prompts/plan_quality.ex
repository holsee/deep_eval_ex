# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/plan_quality/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.PlanQuality do
  @moduledoc """
  Prompt templates for the PlanQuality metric.

  PlanQuality extracts the user's task (with
  `DeepEvalEx.Prompts.StepEfficiency.extract_task_from_trace/1`) and the
  plan the agent stated (with
  `DeepEvalEx.Prompts.PlanAdherence.extract_plan_from_trace/1`) from its
  trace, then scores the plan itself: is it complete, ordered, minimal and
  specific enough to accomplish the task?

  Each function renders deepeval 4.3.1's `PlanQualityMetric` template of
  the same name byte for byte, the plan printed one step per line.
  deepeval's templates always hold the multimodal input rules, for any
  test case, so these do too: the `:multimodal` option changes nothing.

  deepeval renders `evaluate_plan_quality` with an explicit
  `template_class`, which bypasses a user's `evaluation_template`, so only
  the System One templates, `system_one_score/0` and
  `system_one_questions/1` (deepeval's `_experimental_system_one_score`
  and `_experimental_system_one_questions`), can be overridden (see
  `DeepEvalEx.Prompts.EvaluationTemplate`).
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      system_one_score: 0,
      system_one_questions: 1
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to score, from `0.0` to `1.0`, the quality of the
  agent's plan for the user's task.

  ## Options

  - `:user_task` - the task extracted from the trace (required)
  - `:agent_plan` - the extracted plan, its steps joined with newlines
    (required)
  - `:multimodal` - accepted as deepeval's template takes it; the
    multimodal input rules are always printed
  """
  @spec evaluate_plan_quality(keyword()) :: String.t()
  def evaluate_plan_quality(opts) do
    user_task = Keyword.fetch!(opts, :user_task)
    agent_plan = Keyword.fetch!(opts, :agent_plan)

    """
    You are a **plan quality evaluator**. Your task is to critically assess the **quality, completeness, and optimality** of an AI agent's plan to accomplish the given user task.

    INPUTS:

    - **User Task:** The user's explicit goal or instruction.
    - **Agent Plan:** The ordered list of steps the agent intends to follow to achieve that goal.

    EVALUATION OBJECTIVE:

    Judge the **intrinsic quality** of the plan — whether the plan itself is strong enough to fully and efficiently achieve the user's task.

    The evaluation must be **strict**.  If the plan is incomplete, inefficient, redundant, or missing critical details, assign a very low score.

    STRICT EVALUATION CRITERIA:

    1. Completeness (Most Important)
    - The plan must fully address all major requirements of the user task.  
    - Missing even one critical subtask or dependency should reduce the score sharply.
    - The plan must include all prerequisite actions necessary for the final outcome.

    2. Logical Coherence
    - Steps must follow a clear, rational sequence that leads directly to completing the task.  
    - Disordered, redundant, or circular reasoning should be penalized heavily.
    - Every step must have a clear purpose; no filler or irrelevant actions.

    3. Optimality and Efficiency
    - The plan must be **minimal but sufficient** — no unnecessary or repetitive steps.
    - If a more direct, simpler, or logically superior plan could achieve the same outcome, the current plan should receive a lower score.

    4. Level of Detail
    - Each step should be specific enough for an agent to execute it reliably without ambiguity.  
    - Vague steps (e.g., “Do research”, “Handle results”) that lack operational clarity 
    lower the score.

    5. Alignment with Task
    - The plan must explicitly and directly target the user's stated goal.  
    - If any step diverges from the main objective, the score should drop significantly.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ---

    SCORING SCALE (STRICT)

    - **1.0 — Excellent plan**
    - Fully complete, logically ordered, and optimally efficient.  
    - No missing, redundant, or ambiguous steps.  
    - Directly fulfills every aspect of the user task.

    - **0.75 — Good plan**
    - Covers nearly all aspects of the task with clear logic.  
    - Minor gaps or small inefficiencies that do not block task completion.

    - **0.5 — Adequate but flawed plan**
    - Partially complete; key details missing or step order inefficient.  
    - Some ambiguity or redundancy that would likely affect execution success.

    - **0.25 — Weak plan**
    - Major missing steps or unclear logic.  
    - The plan would likely fail to complete the task as written.

    - **0.0 — Inadequate plan**
    - Irrelevant, incoherent, or severely incomplete plan.  
    - Does not align with the user’s task or cannot plausibly achieve it.

    *When in doubt, assign the lower score.*

    OUTPUT FORMAT:

    Return a JSON object with this exact structure:

    {
      "score": 0.0,
      "reason": "1-3 short, precise sentences explaining what the plan lacks or how it could fail."
    }

    The `"reason"` must:
    - Reference specific missing, unclear, or inefficient steps.
    - Avoid vague language (“seems fine”, “mostly works”).
    - Use objective terms describing gaps or weaknesses.

    PROVIDED DATA

    User Task:
    #{user_task}

    Agent Plan:
    #{agent_plan}


    JSON:\
    """
  end

  @doc """
  The question a System One model is asked under the `:hybrid` eval mode,
  deepeval's `_experimental_system_one_score` template: the instructions
  of a Score over five plan quality levels, about a state holding the
  `task` and the `plan` (see `DeepEvalEx.SystemOne.Spec.Score`).
  """
  @spec system_one_score() :: String.t()
  def system_one_score do
    "How good is `plan` for accomplishing `task`? A strong plan covers every requirement " <>
      "and prerequisite of `task`, has only necessary steps in a logical order, and each " <>
      "step is specific enough to execute. Judge the plan itself, not how it was carried out."
  end

  @doc """
  The questions a System One model answers under the `:system_one` eval
  mode, deepeval's `_experimental_system_one_questions` template: a JSON
  array of a weighted Choice, a Choice and a five-level Choice, each with
  the not-applicable option "The agent states no plan", which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads. They ask about the plan
  the agent states in the state's `trace`, or without one in the test
  case's `actual_output`.

  ## Options

  - `:has_trace` - whether the state holds the `trace` (required)
  """
  @spec system_one_questions(keyword()) :: String.t()
  def system_one_questions(opts) do
    {source, goal} =
      if Keyword.fetch!(opts, :has_trace),
        do:
          {"`trace` (in its reasoning, thoughts or an explicit plan)",
           "the task the user gave in the root span's input of `trace`"},
        else: {"`actual_output`", "the task the user asked for in `input`"}

    complete =
      Python.tojson(
        "Would the plan the agent states in #{source}, if carried out as written, fully " <>
          "accomplish #{goal}, covering every requirement and prerequisite?"
      )

    steps =
      Python.tojson(
        "Is every step of the plan the agent states in #{source} specific enough to execute, " <>
          "necessary for #{goal}, and in a logical order, with no vague, redundant or " <>
          "off-task step?"
      )

    question =
      Python.tojson(
        "How good is the plan the agent states in #{source} for accomplishing #{goal}?"
      )

    no_plan = Python.tojson("The agent states no plan")

    """


    [
      {
        "type": "choice",
        "question": #{complete},
        "options": {"Yes, the plan is complete": 1.0, "No, the plan misses a requirement or prerequisite": 0.0, #{no_plan}: null},
        "weight": 2
      },
      {
        "type": "choice",
        "question": #{steps},
        "options": {"Yes, every step is clear, necessary and well ordered": 1.0, "No, some step is vague, redundant, off-task or out of order": 0.0, #{no_plan}: null}
      },
      {
        "type": "choice",
        "question": #{question},
        "options": {"Inadequate plan": 0.0, "Weak plan": 0.25, "Adequate but flawed plan": 0.5, "Good plan": 0.75, "Excellent plan": 1.0, #{no_plan}: null}
      }
    ]\
    """
  end
end
