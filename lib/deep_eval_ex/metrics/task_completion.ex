# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/task_completion/task_completion.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.TaskCompletion do
  @moduledoc """
  TaskCompletion, deepeval 4.3.1's `TaskCompletionMetric`: how well an
  agent accomplished the task it was given, judged from its trace.

  It requires the trace (`requires_trace?/0`): run it on a traced
  component or trace with `DeepEvalEx.evaluate_traced/3` or
  `DeepEvalEx.ExUnit.assert_trace/3`, which give the test case its nested
  trace dict (`:trace_dict`). It also works on a plain
  `DeepEvalEx.TestCase` without a trace, from its input, output and tools
  called.

  ## How It Works

  1. **Extract** - the judge states the task the user gave and a strictly
     factual outcome: from the nested trace dict, printed as
     `DeepEvalEx.Tracing.NestedDict.to_json/2` prints it, or without a
     trace from the test case's `input`, `actual_output` and
     `tools_called`
  2. **Task** - the metric's own `:task`, when given, replaces the
     extracted one
  3. **Judge** - the judge scores, from `0` to `1`, how well the outcome
     achieves the task, with a reason: the score is that verdict
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
    metrics: [DeepEvalEx.Metrics.TaskCompletion]
  )

  # Without a trace
  test_case =
    DeepEvalEx.TestCase.new!(
      input: "Book a table for two on Saturday.",
      actual_output: "Booked: Saturday at 19:00, for two.",
      tools_called: [%{name: "book_table", input_parameters: %{"day" => "Saturday"}}]
    )

  {:ok, result} = DeepEvalEx.Metrics.TaskCompletion.measure(test_case)
  result.score    # => 0.9
  result.metadata # => %{task: "Book a table for two on Saturday.", outcome: "..."}
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:task` - The task to judge the outcome against, in place of the
    extracted one (default: `nil`, the extracted task)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Whether a System One verdict gets a reason
    (default: true). The LLM's verdict always has its own
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.TaskCompletion` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `TaskCompletionMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the task and outcome, and the System One
    model scores the verdict, one `DeepEvalEx.SystemOne.Spec.Score`
    request about the `task` and `outcome` over four levels
    (`DeepEvalEx.Prompts.TaskCompletion.system_one_score/0`): the chosen
    level over the highest is the score, and the reason is
    `"Decided by <model>: task completion 0.67."` (`nil` with
    `include_reason: false`). A request that fails falls back to the LLM,
    and the result's `:system_one_fallback_reason` says why
  - `:system_one` - one request answers the whole metric
    (`DeepEvalEx.Prompts.TaskCompletion.system_one_questions/1`, see
    `DeepEvalEx.SystemOne.Runner`) about the test case's trace, compacted
    by `DeepEvalEx.Tracing.CompactTrace`, or without one about its
    `input`, `actual_output` and `tools_called`, and the metric's own
    `task` when given: no LLM call is made, and the score and reason are
    built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.{EvaluationTemplate, ToolCorrectness}
  alias DeepEvalEx.Prompts.TaskCompletion, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.TaskCompletion, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict}

  # deepeval's TASK_COMPLETION_LEVELS, lowest first.
  @task_completion_levels [
    "Not achieved",
    "Partly achieved",
    "Mostly achieved",
    "Fully achieved"
  ]

  @impl true
  def metric_name, do: "Task Completion"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `true`: TaskCompletion judges the trace, deepeval's `requires_trace`.
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
  test case's `input`, `actual_output` and `tools_called`, and the
  metric's own `:task` (the state's `"task"`) when given.

  A multimodal test case has none (`nil`), as in deepeval: System One
  reads text only.
  """
  @impl true
  def system_one_eval_spec(%{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(test_case, opts) do
    has_trace = trace_dict?(test_case.trace_dict)
    task = Keyword.get(opts, :task)

    %EvalSpec{
      evaluation_params: if(has_trace, do: [], else: [:input, :actual_output, :tools_called]),
      questions:
        Scored.parse!(
          EvaluationTemplate.render(opts, Template, :system_one_questions,
            has_trace: has_trace,
            has_task: task != nil
          )
        ),
      extra_state: [
        trace: if(has_trace, do: CompactTrace.compact(test_case.trace_dict)),
        task: task
      ]
    }
  end

  @doc """
  Measures how well the agent accomplished its task.

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

    with {:ok, {extracted_task, outcome}} <- extract_task_and_outcome(test_case, opts),
         task = Keyword.get(opts, :task) || extracted_task,
         {:ok, {verdict, reason}} <- generate_verdict(task, outcome, opts) do
      score = BaseMetric.strict_score(verdict, Keyword.put(opts, :threshold, threshold))

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Task: #{task}",
            "Outcome: #{outcome}",
            "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
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
         metadata: %{task: task, outcome: outcome}
       )}
    end
  end

  # deepeval's _extract_task_and_outcome: from the nested trace dict when
  # the test case has one, else from its input, output and tools called.
  defp extract_task_and_outcome(test_case, opts) do
    prompt =
      if trace_dict?(test_case.trace_dict) do
        EvaluationTemplate.render(opts, Template, :extract_task_and_outcome_from_trace,
          trace_json: NestedDict.to_json(test_case.trace_dict)
        )
      else
        EvaluationTemplate.render(opts, Template, :extract_goal_and_outcome,
          input: test_case.input,
          actual_output: test_case.actual_output,
          tools_called_formatted: ToolCorrectness.format_tools(test_case.tools_called || [])
        )
      end

    case Adapter.generate_with_schema(prompt, Schema.task_and_outcome_schema(), opts) do
      {:ok, response} -> Schema.parse_task_and_outcome(response)
      {:error, _} = error -> error
    end
  end

  # Under :hybrid and :system_one the System One model scores the verdict;
  # the LLM does when it is not asked or fails (deepeval's
  # _generate_verdicts).
  defp generate_verdict(task, outcome, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    spec = %Spec.Score{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_score),
      levels: @task_completion_levels,
      state: [task: task, outcome: outcome]
    }

    case Decision.score(spec, decision_opts) do
      {:ok, value} -> {:ok, {value, system_one_reason(value, decision_opts)}}
      :llm -> llm_verdict(task, outcome, opts)
    end
  end

  # deepeval's _system_one_reason: none without include_reason.
  defp system_one_reason(value, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: Decision.format_reason(opts, "task completion", value)
  end

  defp llm_verdict(task, outcome, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdict,
        task: task,
        actual_outcome: outcome
      )

    case Adapter.generate_with_schema(prompt, Schema.verdict_schema(), opts) do
      {:ok, response} -> Schema.parse_verdict(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's isinstance(test_case._trace_dict, Dict).
  defp trace_dict?(%Jason.OrderedObject{}), do: true
  defp trace_dict?(trace_dict), do: is_map(trace_dict) and not is_struct(trace_dict)
end
