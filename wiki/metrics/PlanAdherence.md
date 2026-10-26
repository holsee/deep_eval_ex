# PlanAdherence Metric

PlanAdherence measures how strictly an agent followed the plan it stated. It is a trace metric: it reads the agent's whole run, the nested trace dict a traced evaluation gives the test case, finds the plan the agent wrote down in its reasoning, thoughts or an explicit plan, and checks the rest of the trace against it: every planned step carried out, in order, and nothing done outside the plan. Whether the plan was good, or the task accomplished, is not judged (pair it with [PlanQuality](PlanQuality.md) and [TaskCompletion](TaskCompletion.md) for that).

## When to Use

- Catching agents that say one thing and do another
- Spotting skipped, reordered or unplanned tool calls
- Keeping a plan-then-execute agent honest as its prompts change

## How It Works

1. **Extract the task** - the judge states the user's task from the nested trace dict, printed as deepeval's `serialize_to_json(trace_dict, indent=2)` (StepEfficiency's prompt)
2. **Extract the plan** - the judge lists the steps of the plan the trace states, and only those it states
3. **Score** - the judge scores, from `0.0` to `1.0`, how strictly the trace follows the plan, with a reason. The prompt is adversarial: any deviation caps the score at `0.5`
4. **Higher score is better** - Success when score ≥ threshold

When the trace holds no plan, nothing is scored: the score is the integer `1`, with the reason "There were no plans to evaluate within the trace of your agent's execution. ...", as deepeval's. On a test case without a trace the prompts print the trace as `null`: run the metric in a traced evaluation.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The user's request (`"None"` on a traced span without one) |
| `:actual_output` | The agent's final output |

`requires_trace?/0` is `true`: in a traced evaluation the test case also carries the trace as `:trace_dict`.

## Basic Usage

```elixir
# On the agent span: the span's own trace is judged
deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.PlanAdherence] do
  ...
end

# In an ExUnit test
assert_trace golden, [DeepEvalEx.Metrics.PlanAdherence], fn -> MyApp.Agent.run(golden.input) end
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides the System One prompts (`DeepEvalEx.Prompts.PlanAdherence`); as in deepeval, the LLM prompts are not overridable |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `PlanAdherenceMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the task and the plan; the System One model takes the score, one request about the `task`, the `plan` and the `trace` (compacted by `DeepEvalEx.Tracing.CompactTrace`) with a five-level Score (`No adherence` to `Perfect adherence`) keyed `verdict`. The chosen level over the highest is the score, with the reason `"Decided by fake-jev: plan adherence 1.00, confidence 0.55."`. Without a trace the LLM scores. A failed request falls back to the LLM and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request answers the whole metric with three Choices about the compacted trace (or, without a trace, the test case's `input`, `actual_output` and `tools_called`); no LLM is called. Each Choice has the option "The agent states no plan", which does not count: when every answer takes it, the score is `1`

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Plan Adherence",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "Step 1 was carried out with an extra web search; step 3 has no matching action.",
  metadata: %{
    task: "Book a table for two at Café Odéon on Saturday.",
    plan: ["Find the restaurant", "Book the table", "Confirm the booking"]
  }
}
```

## Source

Ported from `deepeval/metrics/plan_adherence/plan_adherence.py`
