# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/plan_quality/plan_quality.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.PlanQuality do
  @moduledoc """
  PlanQuality, deepeval 4.3.1's `PlanQualityMetric`: how good the plan an
  agent stated is for the task it was given, judged from its trace. A
  complete, ordered, minimal plan of specific steps scores high; how the
  plan was carried out is not judged (see `DeepEvalEx.Metrics.PlanAdherence`).

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
  3. **Score** - the judge scores the plan, from `0.0` to `1.0`, with a
     reason. When the trace holds no plan, nothing is scored: the score is
     the integer `1`, with deepeval's reason saying so
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
    metrics: [DeepEvalEx.Metrics.PlanQuality]
  )

  # Or on a traced component: the span's own trace is judged
  deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.PlanQuality] do
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
    `DeepEvalEx.Prompts.PlanQuality` (default: `nil`, deepeval's
    templates). As in deepeval, the LLM prompts cannot be overridden
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `PlanQualityMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the task and the plan, and the System One
    model scores the plan, one `DeepEvalEx.SystemOne.Spec.Score` request
    about the `task` and the `plan` over five levels
    (`DeepEvalEx.Prompts.PlanQuality.system_one_score/0`): the chosen
    level over the highest is the score, and the reason is
    `"Decided by <model>: plan quality 0.75."`. For a multimodal test
    case the LLM scores. A request that fails falls back to the LLM, and
    the result's `:system_one_fallback_reason`
    says why
  - `:system_one` - one request answers the whole metric
    (`DeepEvalEx.Prompts.PlanQuality.system_one_questions/1`, see
    `DeepEvalEx.SystemOne.Runner`) about the trace compacted by
    `DeepEvalEx.Tracing.CompactTrace`, or without one about the test
    case's `input`, `actual_output` and `tools_called`. Every question
    has the option "The agent states no plan", which does not count:
    when every answer takes it the score is `1`, as in the LLM chain.
    No LLM call is made
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
  alias DeepEvalEx.Prompts.PlanQuality, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.PlanQuality, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict}

  # deepeval's PLAN_QUALITY_LEVELS, lowest first.
  @plan_quality_levels [
    "Inadequate plan",
    "Weak plan",
    "Adequate but flawed plan",
    "Good plan",
    "Excellent plan"
  ]

  # a_measure's reason when the trace holds no plan (measure() without
  # async_mode words it differently; DeepEvalEx follows the default).
  @no_plan_reason "There are no plans to evaluate within the trace of your agent's execution. " <>
                    "Please check if the agent's planning or reasoning or thinking is stored in " <>
                    "the trace attributes."

  @impl true
  def metric_name, do: "Plan Quality"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `true`: PlanQuality judges the trace, deepeval's `requires_trace`.
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

  A multimodal test case has none (`nil`), as in deepeval: System One
  reads text only.
  """
  @impl true
  def system_one_eval_spec(%{multimodal: true}, _opts), do: nil

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
  Measures the quality of the plan the agent stated for its task.

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

  # Under :hybrid and :system_one the System One model scores the plan;
  # the LLM does for a multimodal test case, or when it is not asked or
  # fails (deepeval's _get_plan_quality_score).
  defp get_score(task, plan, test_case, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.score(score_spec(task, plan, test_case, opts), decision_opts) do
      {:ok, value} ->
        {:ok,
         %{score: value, reason: Decision.format_reason(decision_opts, "plan quality", value)}}

      :llm ->
        llm_score(task, plan, opts)
    end
  end

  # deepeval's _system_one_score_spec: none for a multimodal test case.
  defp score_spec(_task, _plan, %{multimodal: true}, _opts), do: nil

  defp score_spec(task, plan, _test_case, opts) do
    %Spec.Score{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_score),
      levels: @plan_quality_levels,
      state: [task: task, plan: plan]
    }
  end

  # deepeval renders it with an explicit template_class, so no
  # :evaluation_template overrides it.
  defp llm_score(task, plan, opts) do
    prompt = Template.evaluate_plan_quality(user_task: task, agent_plan: Enum.join(plan, "\n"))

    case Adapter.generate_with_schema(prompt, Schema.score_schema(), opts) do
      {:ok, response} -> Schema.parse_score(response)
      {:error, _} = error -> error
    end
  end
end
