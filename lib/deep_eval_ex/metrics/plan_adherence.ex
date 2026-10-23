# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/plan_adherence/plan_adherence.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.PlanAdherence do
  @moduledoc """
  PlanAdherence, deepeval 4.3.1's `PlanAdherenceMetric`: how strictly an
  agent followed the plan it stated, judged from its trace. Every planned
  step must be carried out, in order, and nothing outside the plan done;
  whether the plan was good, or the task accomplished, is not judged (see
  `DeepEvalEx.Metrics.PlanQuality`).

  It requires the trace (`requires_trace?/0`): run it on a traced
  component or trace with `DeepEvalEx.evaluate_traced/3` or
  `DeepEvalEx.ExUnit.assert_trace/3`, which give the test case its nested
  trace dict (`:trace_dict`). On a test case without one, its prompts print
  the trace as `null`, as deepeval's do.

  ## How It Works

  1. **Extract the task** - the judge states the user's task from the
     nested trace dict, printed as `DeepEvalEx.Tracing.NestedDict.to_json/2`
     prints it (`DeepEvalEx.Prompts.StepEfficiency.extract_task_from_trace/1`)
  2. **Extract the plan** - the judge lists the steps of the plan the
     agent stated in its reasoning, thoughts or an explicit plan
     (`DeepEvalEx.Prompts.PlanAdherence.extract_plan_from_trace/1`)
  3. **Score** - the judge scores, from `0.0` to `1.0`, how strictly the
     trace follows the plan, with a reason. When the trace holds no plan,
     nothing is scored: the score is the integer `1`, with deepeval's
     reason saying so
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
    metrics: [DeepEvalEx.Metrics.PlanAdherence]
  )

  # Or on a traced component: the span's own trace is judged
  deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.PlanAdherence] do
    ...
  end
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding the System One prompts,
    see `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.PlanAdherence` (default: `nil`, deepeval's
    templates). As in deepeval, the LLM prompts cannot be overridden
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `PlanAdherenceMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the task and the plan, and the System One
    model scores the adherence, one `DeepEvalEx.SystemOne.Spec.Score`
    request about the `task`, the `plan` and the `trace` (compacted by
    `DeepEvalEx.Tracing.CompactTrace`) over five levels
    (`DeepEvalEx.Prompts.PlanAdherence.system_one_score/0`): the chosen
    level over the highest is the score, and the reason is
    `"Decided by <model>: plan adherence 0.75."`. Without a trace the LLM
    scores. A request that fails falls back to the LLM, and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request answers the whole metric
    (`DeepEvalEx.Prompts.PlanAdherence.system_one_questions/1`, see
    `DeepEvalEx.SystemOne.Runner`) about the compacted trace, or without
    one about the test case's `input`, `actual_output` and
    `tools_called`. Every question has the option "The agent states no
    plan", which does not count: when every answer takes it the score is
    `1`, as in the LLM chain. No LLM call is made
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.AgentPlan,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.PlanAdherence, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.PlanAdherence, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict}

  # deepeval's PLAN_ADHERENCE_LEVELS, lowest first.
  @plan_adherence_levels [
    "No adherence",
    "Weak adherence",
    "Partial adherence",
    "Strong adherence",
    "Perfect adherence"
  ]

  @no_plan_reason "There were no plans to evaluate within the trace of your agent's execution. " <>
                    "Please check if the agent's planning or reasoning or thinking is stored in " <>
                    "any one of the trace attributes."

  @impl true
  def metric_name, do: "Plan Adherence"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `true`: PlanAdherence judges the trace, deepeval's `requires_trace`.
  """
  @impl true
  def requires_trace?, do: true

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  compacted trace (the state's `"trace"`), or without a trace about the
  test case's `input`, `actual_output` and `tools_called`.
  """
  @impl true
  def system_one_eval_spec(test_case, opts) do
    has_trace = AgentPlan.trace_dict?(test_case.trace_dict)

    %EvalSpec{
      evaluation_params: if(has_trace, do: [], else: [:input, :actual_output, :tools_called]),
      questions:
        Scored.parse!(
          EvaluationTemplate.render(opts, Template, :system_one_questions, has_trace: has_trace)
        ),
      extra_state: [trace: if(has_trace, do: CompactTrace.compact(test_case.trace_dict))]
    }
  end

  @doc """
  Measures how strictly the agent followed the plan it stated.

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
    trace_json = NestedDict.to_json(test_case.trace_dict)

    with {:ok, task} <- AgentPlan.extract_task(trace_json, opts),
         {:ok, plan} <- AgentPlan.extract_plan(trace_json, opts),
         {:ok, {score, reason}} <- score_plan(task, plan, test_case, threshold, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Task: #{task} \n",
            "Agent Plan: \n#{Verbose.prettify_list(plan)} \n",
            "Final Score: #{Verbose.to_str(score)} \n",
            "Final Reason: #{Verbose.to_str(reason)} \n"
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
         metadata: %{task: task, plan: plan}
       )}
    end
  end

  # No plan, nothing to judge: deepeval scores the integer 1.
  defp score_plan(_task, [], _test_case, _threshold, _opts), do: {:ok, {1, @no_plan_reason}}

  defp score_plan(task, plan, test_case, threshold, opts) do
    with {:ok, verdict} <- get_score(task, plan, test_case, opts) do
      score = BaseMetric.strict_score(verdict.score, Keyword.put(opts, :threshold, threshold))
      {:ok, {score, verdict.reason}}
    end
  end

  # Under :hybrid and :system_one the System One model scores the
  # adherence of a traced test case; the LLM does without a trace, or when
  # it is not asked or fails (deepeval's _get_plan_adherence_score).
  defp get_score(task, plan, test_case, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.score(score_spec(task, plan, test_case, opts), decision_opts) do
      {:ok, value} ->
        {:ok,
         %{score: value, reason: Decision.format_reason(decision_opts, "plan adherence", value)}}

      :llm ->
        llm_score(task, plan, test_case, opts)
    end
  end

  # deepeval's _system_one_score_spec: none without a trace.
  defp score_spec(task, plan, test_case, opts) do
    if AgentPlan.trace_dict?(test_case.trace_dict) do
      %Spec.Score{
        instructions: EvaluationTemplate.render(opts, Template, :system_one_score),
        levels: @plan_adherence_levels,
        state: [task: task, plan: plan, trace: CompactTrace.compact(test_case.trace_dict)]
      }
    end
  end

  # deepeval renders it with an explicit template_class, so no
  # :evaluation_template overrides it.
  defp llm_score(task, plan, test_case, opts) do
    prompt =
      Template.evaluate_adherence(
        user_task: task,
        agent_plan: Enum.join(plan, "\n"),
        execution_trace_json: NestedDict.to_json(test_case.trace_dict)
      )

    case Adapter.generate_with_schema(prompt, Schema.score_schema(), opts) do
      {:ok, response} -> Schema.parse_score(response)
      {:error, _} = error -> error
    end
  end
end
