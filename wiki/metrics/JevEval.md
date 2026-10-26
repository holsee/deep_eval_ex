# JevEval Metric

JevEval scores a test case with your own questions, answered by a System One model (TypeSafe AI's Jev by default) with calibrated probabilities rather than generated text. You write its decision points as Noul, Score and Choice questions; one System One request answers them all, and the score is built from the answers. To ask about a whole conversation, use [ConversationalJevEval](ConversationalJevEval.md).

## When to Use

- Checks you can phrase as yes/no propositions, ordered levels or a closed set of options
- Scoring without an LLM judge or LLM key: no LLM is called at any point
- Cheap, deterministic, explainable scores (the reason is built from the answers, not generated)
- Judging an agent's trajectory: without `:evaluation_params` the questions are about its trace

## How It Works

1. **Build the state** - the test case fields named by `:evaluation_params`, in that order, as JSON (unset and empty fields are left out); without `:evaluation_params`, `{"trace": ...}`, the test case's trace compacted by `DeepEvalEx.Tracing.CompactTrace`
2. **Ask once** - one System One request answers every question, keyed `q_0`, `q_1`, ...
3. **Value each answer** in `0..1`:
   - `Noul` - P(true)
   - `Score` - the expected level over the top level
   - `Choice` - the credit of the options, weighted by their probabilities; a Choice whose not-applicable options (credit `nil`) carry half the mass or more is dropped
4. **Calculate score** - the weighted mean of the questions that applied, or `1.0` when none did
5. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| the evaluation params | The test case fields the questions refer to, e.g. `:input`, `:actual_output` or `:tools_called` |
| the trace | Without `:evaluation_params`: the test case's trace dict, given by `DeepEvalEx.evaluate_traced/3` or `DeepEvalEx.ExUnit.assert_trace/3` |

## Basic Usage

```elixir
alias DeepEvalEx.Metrics.JevEval
alias DeepEvalEx.SystemOne.Scored

metric =
  JevEval.new(
    name: "Tool Faithfulness",
    evaluation_params: [:input, :actual_output, :tools_called],
    questions: [
      Scored.Noul.new!(
        statement: "Every figure in actual_output appears in a tool output in tools_called.",
        weight: 2
      ),
      Scored.Score.new!(
        question: "How much of actual_output is grounded in tools_called?",
        levels: ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
      ),
      Scored.Choice.new!(
        question: "What did actual_output do with information the tools did not return?",
        options: [left_it_out: 1.0, hedged_it: 0.5, stated_it_as_fact: 0.0, nothing_missing: nil]
      )
    ]
  )

{:ok, result} = JevEval.evaluate(metric, test_case)

result.metric           # => "Tool Faithfulness [JevEval]"
result.score            # => the weighted mean of the answers' values
result.confidence       # => the least decisive answer's confidence
result.score_breakdown  # => one outcome per question
```

The struct can also be passed to `DeepEvalEx.evaluate/3` like any other metric.

## Evaluating a Trace

Without `:evaluation_params`, JevEval asks about the agent's trace instead of test case fields. Pass it where a test case gets its trace, on a trace or a span:

```elixir
metric =
  JevEval.new(
    name: "Trajectory",
    questions: [Scored.Noul.new!(statement: "The agent looked the order up before replying.")]
  )

DeepEvalEx.evaluate_traced(goldens, &MyApp.Support.answer(&1.input), metrics: [metric])
```

See the [Tracing](../guides/Tracing.md) guide.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | string | required | The metric's name; results are named `"<name> [JevEval]"` |
| `:questions` | list | required | `DeepEvalEx.SystemOne.Scored` Noul, Score and Choice questions, at least one |
| `:evaluation_params` | list | the trace | The test case fields the questions refer to, sent in this order; an empty list raises |
| `:system_one_model` | term | TypeSafe Jev | The System One model, anything `DeepEvalEx.SystemOne.Model.resolve/1` accepts |
| `:threshold` | float | 0.5 | Minimum passing score; `nil` for score-only |
| `:strict_mode` | boolean | false | Threshold `1`; the score is `1.0` only when every applicable question is answered at its best |
| `:include_reason` | boolean | true | Build the deterministic reason |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:flaky` | boolean | false | Never decide the test case's success |
| `:include_jev_eval_suffix` | boolean | true | Append `" [JevEval]"` to the name |

## Strict Mode

`strict_mode: true` forces the threshold to `1` and the score to `1.0` when every applicable question is answered at its best (a Noul at P(true) ≥ 0.5, a Score's likeliest level the top one, a Choice's likeliest credited option worth `1.0`) and `0.0` otherwise. Each outcome of the breakdown then says whether it `passed`.

## Eval Modes

JevEval is always decided by System One, whatever the `:eval_mode`: it has no LLM to fall back to and needs no LLM key. It is seeded with zero cost and token counts, which the request adds to; an unpriced request leaves the cost `nil`. A System One error is raised, never caught (`DeepEvalEx.evaluate/3` records it as the metric's error), and the metric is not batched with other metrics.

## Test Case Checks

As deepeval's: a multimodal test case raises `ArgumentError` (Jev has no image input); a missing evaluation param returns `{:error, {:missing_params, params}}`; without `:evaluation_params`, a test case with no trace raises `DeepEvalEx.MissingTestCaseParamsError` with deepeval's message.

## Source

Ported from `deepeval/metrics/jev_eval/jev_eval.py` and `deepeval/metrics/jev_eval/utils.py`
