# PlanQuality Metric

PlanQuality measures how good the plan an agent stated is for the task it was given. It is a trace metric: it reads the agent's whole run, the nested trace dict a traced evaluation gives the test case, finds the plan the agent wrote down in its reasoning, thoughts or an explicit plan, and judges the plan itself: does it cover every requirement, in a logical order, with only necessary steps, each specific enough to execute? How the plan was carried out is not judged (pair it with [PlanAdherence](PlanAdherence.md) for that).

## When to Use

- Checking a planning agent thinks before it acts
- Catching plans that skip a prerequisite or wander off the task
- Comparing planner prompts on the same goldens

## How It Works

1. **Extract the task** - the judge states the user's task from the nested trace dict, printed as deepeval's `serialize_to_json(trace_dict, indent=2)` (StepEfficiency's prompt)
2. **Extract the plan** - the judge lists the steps of the plan the trace states, and only those it states (PlanAdherence's prompt)
3. **Score** - the judge scores the plan from `0.0` to `1.0`, with a reason. The prompt is strict: when in doubt, the lower score
4. **Higher score is better** - Success when score ≥ threshold

When the trace holds no plan, nothing is scored: the score is the integer `1`, with the reason "There are no plans to evaluate within the trace of your agent's execution. ...", as deepeval's. On a test case without a trace the prompts print the trace as `null`: run the metric in a traced evaluation.

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
  metrics: [DeepEvalEx.Metrics.PlanQuality, DeepEvalEx.Metrics.PlanAdherence]
)

# In an ExUnit test
assert_trace golden, [DeepEvalEx.Metrics.PlanQuality], fn -> MyApp.Agent.run(golden.input) end
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides the System One prompts (`DeepEvalEx.Prompts.PlanQuality`); as in deepeval, the LLM prompts are not overridable |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `PlanQualityMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the task and the plan; the System One model takes the score, one request about the `task` and the `plan` with a five-level Score (`Inadequate plan` to `Excellent plan`) keyed `verdict`. The chosen level over the highest is the score, with the reason `"Decided by fake-jev: plan quality 0.75, confidence 0.40."`. A failed request falls back to the LLM and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request answers the whole metric with three Choices about the compacted trace (or, without a trace, the test case's `input`, `actual_output` and `tools_called`); no LLM is called. Each Choice has the option "The agent states no plan", which does not count: when every answer takes it, the score is `1`

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Plan Quality",
  score: 0.75,
  success: true,
  threshold: 0.5,
  reason: "The plan does not say how the booking is confirmed.",
  metadata: %{
    task: "Book a table for two at Café Odéon on Saturday.",
    plan: ["Find the restaurant", "Book the table", "Confirm the booking"]
  }
}
```

## Source

Ported from `deepeval/metrics/plan_quality/plan_quality.py`
