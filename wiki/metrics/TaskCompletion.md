# TaskCompletion Metric

TaskCompletion measures how well an agent accomplished the task it was given. It is a trace metric: it reads the agent's whole run, the nested trace dict a traced evaluation gives the test case, and judges whether the outcome the trace shows achieves the task the user set. It also works on a plain test case without a trace, from its input, output and tools called.

## When to Use

- Checking a tool-calling agent finishes the job, not just answers plausibly
- Regression testing agents run with `DeepEvalEx.evaluate_traced/3` or `DeepEvalEx.ExUnit.assert_trace/3`
- Judging a sub-agent on its own span, as a span metric

## How It Works

1. **Extract** - the judge states the task the user gave and a strictly factual outcome: from the nested trace dict (printed as deepeval's `serialize_to_json(trace_dict, indent=2)`), or without a trace from the test case's `input`, `actual_output` and `tools_called`
2. **Task** - the metric's own `:task`, when given, replaces the extracted one
3. **Judge** - the judge scores, from `0` to `1`, how well the outcome achieves the task, with a reason: the score is that verdict
4. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The user's request (`"None"` on a traced span without one) |
| `:actual_output` | The agent's final output |

`requires_trace?/0` is `true`: in a traced evaluation the test case also carries the trace as `:trace_dict`.

## Basic Usage

```elixir
# Over goldens, judging each whole trace
DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
  metrics: [DeepEvalEx.Metrics.TaskCompletion]
)

# On one span of the agent
deftraced plan_trip(request), type: :agent, metrics: [DeepEvalEx.Metrics.TaskCompletion] do
  ...
end

# Without a trace
test_case =
  DeepEvalEx.TestCase.new!(
    input: "Book a table for two on Saturday.",
    actual_output: "Booked: Saturday at 19:00, for two.",
    tools_called: [%{name: "book_table", input_parameters: %{"day" => "Saturday"}}]
  )

{:ok, result} = DeepEvalEx.Metrics.TaskCompletion.measure(test_case)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:task` | string | `nil` | The task to judge the outcome against, in place of the extracted one |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Whether a System One verdict gets a reason (the LLM's always has one) |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TaskCompletion`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TaskCompletionMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the task and outcome; the System One model takes the verdict, one request about the `task` and `outcome` with a four-level Score (`Not achieved` to `Fully achieved`) keyed `verdict`. The chosen level over the highest is the score, with the reason `"Decided by fake-jev: task completion 0.67, confidence 0.60."`. A failed request falls back to the LLM and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request answers the whole metric with two Nouls and a Score about the trace, compacted by `DeepEvalEx.Tracing.CompactTrace` (or, without a trace, the test case's `input`, `actual_output` and `tools_called`), and the metric's own `task` when given; no LLM is called

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Task Completion",
  score: 0.9,
  success: true,
  threshold: 0.5,
  reason: "The table was booked as asked.",
  metadata: %{
    task: "Book a table for two on Saturday.",
    outcome: "The system booked a table for two on Saturday at 19:00."
  }
}
```

## Source

Ported from `deepeval/metrics/task_completion/task_completion.py`
