# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/goal_accuracy/goal_accuracy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.GoalAccuracy do
  @moduledoc """
  GoalAccuracy, deepeval 4.3.1's `GoalAccuracyMetric`: how fully the
  assistant of a `DeepEvalEx.ConversationalTestCase` achieves each goal the
  user sets, and how good and well followed its plan for it is.

  ## How It Works

  1. **Split the conversation** - into unit interactions
     (`DeepEvalEx.Metrics.Utils.Turns.get_unit_interactions/1`). Each one's
     goal is `"User messages: \\n"` and its leading user messages, one per
     line; its steps are the assistant's messages so far, one step per
     assistant turn after the first turn of the unit, each step holding
     every message before it too (with its tool calls, as deepeval's
     `print_tools_called` prints them)
  2. **Score each goal** - the judge scores how fully the steps achieve the
     goal, from `0.0` to `1.0`, with a reason
  3. **Score each plan** - the judge scores the quality of the assistant's
     plan and how closely it followed it, likewise
  4. **Calculate score** - the mean of the mean goal score and the mean
     plan score (each `0.0` without unit interactions)
  5. **Explain** - the judge writes the reason as plain text from every
     score and reason. As in deepeval, it always does: `:include_reason` is
     not read
  6. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.GoalAccuracy}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "Book me a table for two on Saturday."},
        %{role: :assistant, content: "Booked: Café Odéon, Saturday at 19:00, for two."}
      ]
    )

  {:ok, result} = GoalAccuracy.measure(test_case)
  result.score   # => 0.875 (goal 1.0, plan 0.75)
  result.success # => true (0.875 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.GoalAccuracy` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `GoalAccuracyMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model scores each goal and each plan, one
    `DeepEvalEx.SystemOne.Spec.Score` request each about the unit's `task`
    and `steps_taken`, over five levels
    (`DeepEvalEx.Prompts.GoalAccuracy.system_one_goal_score/0` and
    `system_one_plan_score/0`): the chosen level over the highest is the
    score, and the reason is `"Decided by <model>: goal accuracy 0.75."`.
    A request that fails falls back to the LLM for that score, and the
    result's `:system_one_fallback_reason` says why. The LLM still writes
    the final reason
  - `:system_one` - one request about the whole conversation, each turn's
    `role`, `content` and `tools_called`, answers the whole metric
    (`DeepEvalEx.Prompts.GoalAccuracy.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  A multimodal test case is always judged by the LLM.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.Turns,
    Metrics.Utils.Verbose,
    Prompts.Python,
    Result,
    Turn
  }

  alias DeepEvalEx.Prompts.{EvaluationTemplate, ToolCorrectness}
  alias DeepEvalEx.Prompts.GoalAccuracy, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.GoalAccuracy, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  # deepeval's GOAL_ACCURACY_LEVELS and PLAN_QUALITY_LEVELS, lowest first.
  @goal_accuracy_levels [
    "Not achieved",
    "Weak attempt",
    "Partially achieved",
    "Mostly achieved",
    "Fully achieved"
  ]

  @plan_quality_levels [
    "No plan",
    "Weak or fragmented plan, rarely followed",
    "Partial plan, partly followed",
    "Clear plan, mostly followed",
    "Complete plan, fully followed"
  ]

  @impl true
  def metric_name, do: "Goal Accuracy"

  @impl true
  def required_params, do: [:role, :content]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  conversation's turns, each with its `role`, `content` and `tools_called`.
  `nil` for a multimodal test case.
  """
  @impl true
  def system_one_eval_spec(%ConversationalTestCase{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params() ++ [:tools_called],
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how accurately the assistant achieves the user's goals.

  ## Options

  See the moduledoc, plus:

  - `:adapter` - LLM adapter to use
  """
  def do_measure(test_case, opts) do
    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, opts)
    end
  end

  defp measure_with_llm(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    template_opts = Keyword.put(opts, :multimodal, test_case.multimodal)
    goals = test_case.turns |> Turns.get_unit_interactions() |> Enum.map(&goal_and_steps/1)

    with {:ok, goal_scores} <- score_all(goals, :goal, template_opts),
         {:ok, plan_scores} <- score_all(goals, :plan, template_opts),
         score = calculate_score(goal_scores, plan_scores, threshold, opts),
         {:ok, reason} <-
           generate_reason(score, threshold, goal_scores, plan_scores, template_opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Goals and steps taken: \n#{print_goals_and_steps(goals)} \n",
            "Goal evaluations: #{goal_scores |> Enum.map(&score_model/1) |> Verbose.prettify_list()} \n\n" <>
              "Plan evaluations: #{plan_scores |> Enum.map(&score_model/1) |> Verbose.prettify_list()} \n\n" <>
              "Final Score: #{Verbose.to_str(score)}",
            "Final Reason: #{Verbose.to_str(reason)}"
          ],
          opts
        )

      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{goal_scores: goal_scores, plan_scores: plan_scores}
       )}
    end
  end

  # deepeval's _goal_and_steps_taken: the unit's leading user messages, and
  # one step per assistant turn after the unit's first turn, each holding
  # every assistant message (and its tool calls) so far.
  defp goal_and_steps(unit) do
    user_goal =
      unit
      |> Enum.take_while(&(&1.role == :user))
      |> Enum.reduce("User messages: \n", &(&2 <> "#{&1.content}\n"))

    {_messages, steps} =
      unit
      |> Enum.drop(1)
      |> Enum.reduce({"Assistant messages: \n", []}, fn
        %Turn{role: :assistant} = turn, {messages, steps} ->
          messages = messages <> "#{turn.content} \n" <> tools_called(turn.tools_called)
          {messages, [messages | steps]}

        _turn, acc ->
          acc
      end)

    %{user_goal: user_goal, steps_taken: Enum.reverse(steps)}
  end

  defp tools_called(tools) when tools in [nil, []], do: ""

  defp tools_called(tools),
    do: "Tools called: \n#{ToolCorrectness.format_tools(tools)} \n"

  # Every goal's (or plan's) score, in order, as deepeval gathers them.
  defp score_all(goals, kind, opts) do
    Enum.reduce_while(goals, {:ok, []}, fn goal, {:ok, scores} ->
      case score_goal(goal, kind, opts) do
        {:ok, score} -> {:cont, {:ok, [score | scores]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, scores} -> {:ok, Enum.reverse(scores)}
      error -> error
    end
  end

  # Under :hybrid and :system_one the System One model scores the goal (or
  # plan); the LLM does when it is not asked or fails.
  defp score_goal(goal, kind, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.score(system_one_spec(goal, kind, opts), decision_opts) do
      {:ok, value} ->
        {:ok, %{score: value, reason: Decision.format_reason(decision_opts, what(kind), value)}}

      :llm ->
        llm_score(goal, kind, opts)
    end
  end

  # deepeval's _experimental_system_one_spec: none for a multimodal test
  # case.
  defp system_one_spec(goal, kind, opts) do
    if Keyword.fetch!(opts, :multimodal), do: nil, else: score_spec(goal, kind, opts)
  end

  defp score_spec(goal, kind, opts) do
    {template, levels} =
      case kind do
        :goal -> {:system_one_goal_score, @goal_accuracy_levels}
        :plan -> {:system_one_plan_score, @plan_quality_levels}
      end

    %Spec.Score{
      instructions: EvaluationTemplate.render(opts, Template, template),
      levels: levels,
      state: [task: goal.user_goal, steps_taken: goal.steps_taken]
    }
  end

  defp what(:goal), do: "goal accuracy"
  defp what(:plan), do: "plan quality"

  defp llm_score(goal, kind, opts) do
    template = if kind == :goal, do: :get_accuracy_score, else: :get_plan_evaluation_score

    prompt =
      EvaluationTemplate.render(opts, Template, template,
        task: goal.user_goal,
        steps_taken: Enum.join(goal.steps_taken, "\n"),
        multimodal: Keyword.fetch!(opts, :multimodal)
      )

    case Adapter.generate_with_schema(prompt, Schema.score_schema(), opts) do
      {:ok, response} -> Schema.parse_score(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's _calculate_score: the mean of the mean goal score and the
  # mean plan score, each 0.0 without scores.
  defp calculate_score(goal_scores, plan_scores, threshold, opts) do
    score = (mean(goal_scores) + mean(plan_scores)) / 2
    BaseMetric.strict_score(score, Keyword.put(opts, :threshold, threshold))
  end

  defp mean([]), do: 0.0
  defp mean(scores), do: (scores |> Enum.map(& &1.score) |> Enum.sum()) / length(scores)

  # deepeval's _generate_reason: a plain-text answer, without a schema.
  defp generate_reason(score, threshold, goal_scores, plan_scores, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :get_final_reason,
        final_score: score,
        threshold: threshold,
        goal_evaluations:
          Enum.map_join(goal_scores, &"Score: #{Python.repr(&1.score)}, Reason: #{&1.reason}"),
        plan_evalautions:
          Enum.map_join(plan_scores, &"Score: #{Python.repr(&1.score)}, Reason: #{&1.reason} \n"),
        multimodal: Keyword.fetch!(opts, :multimodal)
      )

    Adapter.generate(prompt, opts)
  end

  # deepeval's print_goals_and_steps_taken, its "c" included.
  defp print_goals_and_steps(goals) do
    Enum.map_join(goals, fn goal ->
      "#{goal.user_goal} \nc#{Verbose.prettify_list(goal.steps_taken)} \n\n"
    end)
  end

  # deepeval's GoalScore and PlanScore models.
  defp score_model(score), do: OrderedObject.new(score: score.score, reason: score.reason)
end
