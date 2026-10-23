# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/step_efficiency/step_efficiency.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.StepEfficiency do
  @moduledoc """
  StepEfficiency, deepeval 4.3.1's `StepEfficiencyMetric`: how economically
  an agent carried out its task, judged from its trace. Every redundant,
  repeated or speculative tool call, LLM call or retrieval lowers the
  score; whether the answer is right is not judged.

  It requires the trace (`requires_trace?/0`): run it on a traced
  component or trace with `DeepEvalEx.evaluate_traced/3` or
  `DeepEvalEx.ExUnit.assert_trace/3`, which give the test case its nested
  trace dict (`:trace_dict`). On a test case without one, its prompts print
  the trace as `null`, as deepeval's do.

  ## How It Works

  1. **Extract** - the judge states the user's task from the nested trace
     dict, printed as `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it
  2. **Score** - the judge scores, from `0.0` to `1.0`, how close the
     trace came to the minimal sequence of actions for the task, with a
     reason
  3. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
    metrics: [DeepEvalEx.Metrics.StepEfficiency]
  )

  # Or on a traced component: the span's own trace is judged
  deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.StepEfficiency] do
    ...
  end
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.StepEfficiency` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `StepEfficiencyMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the task, and the System One model scores
    the efficiency, one `DeepEvalEx.SystemOne.Spec.Score` request about
    the `task` and the `trace` (compacted by
    `DeepEvalEx.Tracing.CompactTrace`) over five levels
    (`DeepEvalEx.Prompts.StepEfficiency.system_one_score/0`): the chosen
    level over the highest is the score, and the reason is
    `"Decided by <model>: step efficiency 0.75."`. Without a trace the
    LLM scores. A request that fails falls back to the LLM, and the
    result's `:system_one_fallback_reason` says why
  - `:system_one` - one request answers the whole metric
    (`DeepEvalEx.Prompts.StepEfficiency.system_one_questions/1`, see
    `DeepEvalEx.SystemOne.Runner`) about the compacted trace, or without
    one about the test case's `input`, `actual_output` and
    `tools_called`: no LLM call is made, and the score and reason are
    built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.StepEfficiency, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.StepEfficiency, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict}

  # deepeval's STEP_EFFICIENCY_LEVELS, lowest first.
  @step_efficiency_levels [
    "Highly inefficient",
    "Low efficiency",
    "Moderate efficiency",
    "Strong efficiency",
    "Perfectly efficient"
  ]

  @impl true
  def metric_name, do: "Step Efficiency"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `true`: StepEfficiency judges the trace, deepeval's `requires_trace`.
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
    has_trace = trace_dict?(test_case.trace_dict)

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
  Measures how efficiently the agent carried out its task.

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

    with {:ok, task} <- extract_task(trace_json, opts),
         {:ok, verdict} <- get_score(task, trace_json, test_case, opts) do
      score = BaseMetric.strict_score(verdict.score, Keyword.put(opts, :threshold, threshold))

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Task: #{task} \n",
            "Efficiency Score: #{Verbose.to_str(score)}",
            "Efficiency Reason: #{Verbose.to_str(verdict.reason)}"
          ],
          opts
        )

      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: verdict.reason,
         verbose_logs: verbose_logs,
         metadata: %{task: task}
       )}
    end
  end

  # deepeval's _extract_task_from_trace.
  defp extract_task(trace_json, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :extract_task_from_trace, trace_json: trace_json)

    case Adapter.generate_with_schema(prompt, Schema.task_schema(), opts) do
      {:ok, response} -> Schema.parse_task(response)
      {:error, _} = error -> error
    end
  end

  # Under :hybrid and :system_one the System One model scores the
  # efficiency of a traced test case; the LLM does without a trace, or
  # when it is not asked or fails (deepeval's _get_score).
  defp get_score(task, trace_json, test_case, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.score(score_spec(task, test_case, opts), decision_opts) do
      {:ok, value} ->
        {:ok,
         %{score: value, reason: Decision.format_reason(decision_opts, "step efficiency", value)}}

      :llm ->
        llm_score(task, trace_json, opts)
    end
  end

  # deepeval's _system_one_score_spec: none without a trace.
  defp score_spec(task, test_case, opts) do
    if trace_dict?(test_case.trace_dict) do
      %Spec.Score{
        instructions: EvaluationTemplate.render(opts, Template, :system_one_score),
        levels: @step_efficiency_levels,
        state: [task: task, trace: CompactTrace.compact(test_case.trace_dict)]
      }
    end
  end

  defp llm_score(task, trace_json, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :get_execution_efficiency,
        task: task,
        trace_json_str: trace_json
      )

    case Adapter.generate_with_schema(prompt, Schema.efficiency_schema(), opts) do
      {:ok, response} -> Schema.parse_efficiency(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's isinstance(test_case._trace_dict, Dict).
  defp trace_dict?(%Jason.OrderedObject{}), do: true
  defp trace_dict?(trace_dict), do: is_map(trace_dict) and not is_struct(trace_dict)
end
