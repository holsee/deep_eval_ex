# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/goal_accuracy/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.GoalAccuracy do
  @moduledoc """
  Prompt templates for the GoalAccuracy metric.

  GoalAccuracy measures, for each unit interaction of a conversation, how
  fully the assistant achieved the user's goal and how good and well
  followed its plan was.

  Each function renders deepeval 4.3.1's `GoalAccuracyMetric` template of
  the same name byte for byte. The templates leave out the multimodal input
  rules, keeping the blank lines around them, unless the `:multimodal`
  option is `true`, as for a multimodal `DeepEvalEx.ConversationalTestCase`.
  The task, steps and evaluations are printed as they are, and the final
  score and threshold as Python's `str()` of them, unformatted, as deepeval
  passes them (see `DeepEvalEx.Prompts.Python`).

  `system_one_goal_score/0`, `system_one_plan_score/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_goal_score`, `_experimental_system_one_plan_score`
  and `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      get_accuracy_score: 1,
      get_plan_evaluation_score: 1,
      get_final_reason: 1,
      system_one_goal_score: 0,
      system_one_plan_score: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to score how fully one unit interaction achieved the
  user's goal.

  ## Options

  - `:task` - the user's goal: `"User messages: \\n"` and the unit's user
    messages, one per line (required)
  - `:steps_taken` - the assistant's steps, joined with newlines (required)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal input rules (default: `false`)
  """
  def get_accuracy_score(opts) do
    task = Keyword.fetch!(opts, :task)
    steps_taken = Keyword.fetch!(opts, :steps_taken)

    """
    You are an expert evaluator assessing the **goal accuracy** of an AI assistant's single interaction.

    PURPOSE:

    Evaluate whether the assistant's **visible output** (what the user actually saw) **fully and correctly achieved the user's stated goal.  
    Ignore internal reasoning, hidden tool calls, or retriever outputs unless their results were explicitly surfaced to the user.

    The evaluation must be **strict and adversarial** — if the goal is not *clearly, fully, and correctly achieved*, assign a low score.

    EVALUATION RULES

    1. **User-visible fulfillment only**
    - Base your judgment solely on what the user would see in the assistant's message.
    - Ignore hidden or internal steps unless their results were explicitly communicated.

    2. **Goal completion**
    - The assistant must explicitly provide everything the user asked for.
    - If even one subpart of the task is missing, incomplete, or vague, the score must be **≤ 0.5**.

    3. **Correctness and relevance**
    - The information provided must be factually correct and directly relevant to the task.
    - Hallucinated or unrelated content automatically lowers the score.

    4. **Self-sufficiency**
    - The visible response must stand on its own; the user should not need prior context or follow-up clarification.

    5. **Strict bias toward failure**
    - When uncertain, assume the goal was **not achieved**.
    - The metric is designed to fail unless the assistant's output is precise, complete, and user-visible.

    #{multimodal_rules(opts)}

    SCORING GUIDE:

    - **1.0** → Goal completely and correctly achieved; all required outputs visible to the user.  
    - **0.75** → Mostly achieved; minor omissions or trivial inaccuracies.  
    - **0.5** → Partially achieved; core goal addressed, but key parts missing or incorrect.  
    - **0.25** → Weak attempt; loosely related but fails to satisfy the user’s request.  
    - **0.0** → Goal not achieved at all; irrelevant, wrong, or missing answer.

    *When in doubt, choose the lower score.*

    OUTPUT FORMAT:

    Return only a valid JSON object with this structure:

    {
      "score": 0.0,
      "reason": "1-3 factual sentences explaining what parts of the user's goal were or were not achieved."
    }

    The reason must:
    - Be objective and concise.
    - Refer to **specific missing or incorrect elements**.
    - Avoid vague language (“somewhat correct”, “pretty accurate”).

    EXAMPLES:

    **Example 1**
    Task: "Translate 'good night' into French."  
    Assistant Reply: "Bonne nuit."  
    →  
    {
      "score": 1.0,
      "reason": "The assistant provided the exact, correct translation requested by the user."
    }

    **Example 2**
    Task: "List three renewable energy sources."  
    Assistant Reply: "Solar and wind energy."  
    →  
    {
      "score": 0.5,
      "reason": "The assistant only listed two sources instead of three, so the goal was partially achieved."
    }

    **Example 3**
    Task: "Summarize this paragraph."  
    Assistant Reply: "It talks about technology."  
    →  
    {
      "score": 0.25,
      "reason": "The summary is too vague and fails to convey key information from the text."
    }

    *** END OF EXAMPLES ***

    USER TASK:
    #{task}

    AGENT STEPS:
    #{steps_taken}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to score the quality of the assistant's plan for one
  unit interaction, and how closely it followed it.

  ## Options

  As for `get_accuracy_score/1`.
  """
  def get_plan_evaluation_score(opts) do
    task = Keyword.fetch!(opts, :task)
    steps_taken = Keyword.fetch!(opts, :steps_taken)

    """
    You are an expert evaluator assessing the **planning quality** and **plan adherence** of an AI agent tasked with fulfilling a user's request.

    OBJECTIVE:

    Evaluate:

    1. **Plan Quality** — Was the agent's plan clear, complete, and logically structured to fully address the user's task?  
    2. **Plan Adherence** — Did the agent consistently follow that plan without unjustified deviations, omissions, or extraneous steps?

    Your judgment must be strict: a plan must be well-formed and execution must align with it for a high score.

    EVALUATION CRITERIA

    - Plan Quality:  
    - The plan should explicitly or implicitly outline all necessary steps to fulfill the user's task.  
    - It must be logically ordered, neither vague nor overly generic.  
    - Missing critical components or unclear structuring lowers the score drastically.

    - Plan Adherence:  
    - Execution must closely match the planned steps.  
    - Any skipped, added, or rearranged steps without clear justification count as plan deviations.  
    - Minor, justified variations are acceptable but reduce the score slightly.

    - General Rules:  
    - If no discernible plan exists, score ≤ 0.5 regardless of task completion.  
    - Tool use should be coherent within the plan, not ad hoc or speculative.  
    - This evaluation excludes correctness or efficiency — focus solely on plan and adherence.

    #{multimodal_rules(opts)}

    SCORING GUIDE:

    - **1.0** → Complete, clear, and logical plan **fully followed** with all steps aligned to the user's goal.  
    - **0.75** → Mostly clear plan with minor omissions or small execution deviations that do not impact the overall strategy.  
    - **0.5** → Partial plan exists but is incomplete, vague, or only partially followed; notable deviations present.  
    - **0.25** → Weak or fragmented plan; execution frequently diverges or lacks coherence with any strategy.  
    - **0.0** → No evidence of a plan; execution appears random or unrelated to the user's task.

    INSTRUCTIONS:

    1. Identify the agent's plan from the steps taken (explicit plans stated or implicit structure).  
    2. Assess plan completeness and logical order relative to the user's task.  
    3. Compare execution steps against the plan to check for adherence, noting any unjustified deviations.  
    4. Deduct points for vagueness, missing critical steps, or inconsistent execution.

    OUTPUT FORMAT:

    Return only a valid JSON object with exactly two fields:

    {
      "score": 0.0,
      "reason": "1-3 concise sentences explaining the quality of the plan and how well execution matched it. Specify missing or extra steps, plan clarity, and adherence issues."
    }

    EXAMPLE:

    User Task: "Plan a business trip including booking a flight, hotel, and preparing an agenda."

    Agent Steps include:
    - Outlined flight, hotel, and agenda steps explicitly.
    - Executed flight and hotel booking steps.
    - Skipped agenda preparation despite mentioning it in the plan.

    Example JSON:

    {
      "score": 0.75,
      "reason": "The agent formed a clear plan covering flights, hotel, and agenda, but failed to execute the agenda preparation step, reducing adherence."
    }

    **** END OF EXAMPLE ****

    INPUTS:

    USER TASK:
    #{task}

    AGENT STEPS:
    #{steps_taken}

    JSON:\
    """
  end

  @doc """
  Generates a prompt for the final reason, a plain-text answer.

  ## Options

  - `:goal_evaluations` - each goal score and reason,
    `"Score: <score>, Reason: <reason>"`, concatenated (required)
  - `:plan_evalautions` - each plan score and reason,
    `"Score: <score>, Reason: <reason> \\n"`, concatenated; deepeval's
    spelling (required)
  - `:final_score` - the metric's score, printed as Python's `str()`
    (required)
  - `:threshold` - the metric's threshold, likewise (required)
  - `:multimodal` - as for `get_accuracy_score/1`
  """
  def get_final_reason(opts) do
    goal_evaluations = Keyword.fetch!(opts, :goal_evaluations)
    plan_evalautions = Keyword.fetch!(opts, :plan_evalautions)
    final_score = Keyword.fetch!(opts, :final_score)
    threshold = Keyword.fetch!(opts, :threshold)

    """
    You are an expert evaluator providing a **final justification** for whether an AI agent has passed or failed an evaluation metric.

    You are given:
    - An agent's goal execution scores and reasons.
    - The agent's plan evaluation scores and reasons.
    - The **final combined score**.
    - The **threshold** required to pass.
    - Whether the result is a **pass** or **fail**.

    Your job is to write a short, precise explanation of **why** the agent passed or failed — taking into account the quality of execution and planning, and the threshold.

    ---

    INSTRUCTIONS:

    - Write 2-4 clear, objective sentences explaining the overall result.
    - Explicitly reference both the task and plan performance — **both must be addressed**.
    - Mention how the final score compares to the threshold.
    - If the agent **passed**, highlight how both task execution and planning were sufficient to meet the goal.
    - If the agent **failed**, explain which aspects (task or plan or both) led to the failure.
    - Avoid vague praise or criticism — ground the reason in the actual scores and justifications.

    #{multimodal_rules(opts)}

    ---

    FORMAT:
    Return only a single string. Do **not** include JSON or any extra formatting.

    ---

    Goal evaluations:
    #{goal_evaluations}

    Plan evaluations:
    #{plan_evalautions}

    Final Score: #{Python.repr(final_score)}
    Threshold: #{Python.repr(threshold)}
    Result: #{result(final_score, threshold)}

    Final Reason:\
    """
  end

  # Jinja's `{% if final_score|float >= threshold|float %}PASS{% else %}FAIL{% endif %}`.
  defp result(final_score, threshold), do: if(final_score >= threshold, do: "PASS", else: "FAIL")

  # deepeval's `{% if multimodal %}{{ _fragments.multimodal_input_rules }}{% endif %}`.
  defp multimodal_rules(opts) do
    if Keyword.get(opts, :multimodal, false) do
      """

      --- MULTIMODAL INPUT RULES ---
      - Treat image content as factual evidence.
      - Only reference visual details that are explicitly and clearly visible.
      - Do not infer or guess objects, text, or details not visibly present.
      - If an image is unclear or ambiguous, mark uncertainty explicitly.
      """
    else
      ""
    end
  end

  @doc """
  The question a System One model is asked about each unit interaction's
  goal under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_goal_score` template: the instructions of a
  Score over five goal accuracy levels, about a state holding the `task`
  and the `steps_taken` (see `DeepEvalEx.SystemOne.Spec.Score`).
  """
  @spec system_one_goal_score() :: String.t()
  def system_one_goal_score do
    "How fully and correctly do the assistant messages the user saw in `steps_taken` " <>
      "achieve the goal in `task`? Judge only what was visible to the user; a missing, " <>
      "vague or incorrect part of the goal lowers the level."
  end

  @doc """
  The question a System One model is asked about each unit interaction's
  plan under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_plan_score` template: the instructions of a
  Score over five plan quality levels, about the same state as
  `system_one_goal_score/0`.
  """
  @spec system_one_plan_score() :: String.t()
  def system_one_plan_score do
    "How clear, complete and logically ordered is the assistant's plan (stated or implied) " <>
      "in `steps_taken` for achieving `task`, and how closely does its execution follow " <>
      "that plan?"
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of a weighted
  Noul and two five-level Scores about the `turns`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every goal the user states in `turns` is fully and correctly achieved in the assistant turns that follow it, as seen by the user.",
        "weight": 2
      },
      {
        "type": "score",
        "question": "Across `turns`, how fully and correctly do the assistant's visible replies achieve the goals the user states?",
        "levels": ["Not achieved", "Weak attempt", "Partially achieved", "Mostly achieved", "Fully achieved"]
      },
      {
        "type": "score",
        "question": "Across `turns`, how clear and complete is the assistant's plan (including its `tools_called`) for each user goal, and how closely does it follow that plan?",
        "levels": ["No plan", "Weak or fragmented plan, rarely followed", "Partial plan, partly followed", "Clear plan, mostly followed", "Complete plan, fully followed"]
      }
    ]\
    """
  end
end
