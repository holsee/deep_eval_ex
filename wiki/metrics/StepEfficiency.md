# StepEfficiency Metric

StepEfficiency measures how economically an agent carried out its task. It is a trace metric: it reads the agent's whole run, the nested trace dict a traced evaluation gives the test case, and scores how close the steps came to the minimal sequence of actions. Every redundant, repeated or speculative tool call, LLM call or retrieval lowers the score; whether the answer is right is not judged (pair it with [TaskCompletion](TaskCompletion.md) for that).

## When to Use

- Catching agents that loop, re-query or call tools they do not need
- Keeping an agent's cost and latency in check as its prompts change
- Comparing two agent designs that reach the same answer

## How It Works

1. **Extract** - the judge states the user's task from the nested trace dict, printed as deepeval's `serialize_to_json(trace_dict, indent=2)`
2. **Score** - the judge scores, from `0.0` to `1.0`, how efficiently the trace carried out the task, with a reason. The prompt is adversarial: when in doubt, a step counts as unnecessary
3. **Higher score is better** - Success when score ≥ threshold

On a test case without a trace both prompts print the trace as `null`, as deepeval's do: run the metric in a traced evaluation.

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
  metrics: [DeepEvalEx.Metrics.StepEfficiency, DeepEvalEx.Metrics.TaskCompletion]
)

# In an ExUnit test
assert_trace golden, [DeepEvalEx.Metrics.StepEfficiency], fn -> MyApp.Agent.run(golden.input) end
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.StepEfficiency`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `StepEfficiencyMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the task; the System One model takes the score, one request about the `task` and the `trace` (compacted by `DeepEvalEx.Tracing.CompactTrace`) with a five-level Score (`Highly inefficient` to `Perfectly efficient`) keyed `verdict`. The chosen level over the highest is the score, with the reason `"Decided by fake-jev: step efficiency 1.00, confidence 0.55."`. Without a trace the LLM scores. A failed request falls back to the LLM and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request answers the whole metric with two Nouls and a Score about the compacted trace (or, without a trace, the test case's `input`, `actual_output` and `tools_called`); no LLM is called

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Step Efficiency",
  score: 0.75,
  success: true,
  threshold: 0.5,
  reason: "The web search was not needed to book the table.",
  metadata: %{task: "Book a table for two at Café Odéon on Saturday."}
}
```

## Source

Ported from `deepeval/metrics/step_efficiency/step_efficiency.py`
