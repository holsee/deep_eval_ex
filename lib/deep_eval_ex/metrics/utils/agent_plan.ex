# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/plan_quality/plan_quality.py and
# deepeval/metrics/plan_adherence/plan_adherence.py
# (_extract_task_from_trace, _extract_plan_from_trace)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.AgentPlan do
  @moduledoc """
  The two extractions PlanQuality and PlanAdherence share, as deepeval
  4.3.1's `_extract_task_from_trace` and `_extract_plan_from_trace`, which
  both metrics define alike.

  Both prompts are borrowed with deepeval's explicit `template_class`
  (`StepEfficiencyMetric` and `PlanAdherenceMetric`), so a metric's
  `:evaluation_template` never overrides them.
  """

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.Prompts.{PlanAdherence, StepEfficiency}
  alias DeepEvalEx.Schemas.MetricOutputs.PlanAdherence, as: PlanSchema
  alias DeepEvalEx.Schemas.MetricOutputs.StepEfficiency, as: TaskSchema

  @doc """
  The user's task, extracted by the judge from `trace_json` (the nested
  trace dict as `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it) with
  `DeepEvalEx.Prompts.StepEfficiency.extract_task_from_trace/1`.
  """
  @spec extract_task(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def extract_task(trace_json, opts) do
    prompt = StepEfficiency.extract_task_from_trace(trace_json: trace_json)

    case Adapter.generate_with_schema(prompt, TaskSchema.task_schema(), opts) do
      {:ok, response} -> TaskSchema.parse_task(response)
      {:error, _} = error -> error
    end
  end

  @doc """
  The plan the agent stated, its steps in order (empty when the trace holds
  none), extracted by the judge from `trace_json` with
  `DeepEvalEx.Prompts.PlanAdherence.extract_plan_from_trace/1`.
  """
  @spec extract_plan(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def extract_plan(trace_json, opts) do
    prompt = PlanAdherence.extract_plan_from_trace(trace_json_str: trace_json)

    case Adapter.generate_with_schema(prompt, PlanSchema.plan_schema(), opts) do
      {:ok, response} -> PlanSchema.parse_plan(response)
      {:error, _} = error -> error
    end
  end

  @doc """
  Whether `trace_dict` is a nested trace dict, deepeval's
  `isinstance(test_case._trace_dict, Dict)`.
  """
  @spec trace_dict?(term()) :: boolean()
  def trace_dict?(%Jason.OrderedObject{}), do: true
  def trace_dict?(trace_dict), do: is_map(trace_dict) and not is_struct(trace_dict)
end
