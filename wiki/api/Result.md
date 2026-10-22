# Result

`DeepEvalEx.Result` represents the result of evaluating a test case against a metric.

## Overview

Every metric evaluation returns a `Result` struct containing the score, success status, and optional reasoning from LLM-based metrics.

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `metric` | `String.t()` | Name of the metric that produced this result |
| `score` | `number() \| nil` | Numeric score from 0.0 to 1.0; `nil` when the metric errored or was skipped |
| `success` | `boolean() \| nil` | Whether the score meets the threshold; `nil` for a score-only metric (no threshold), `false` when errored |
| `reason` | `String.t()` | Explanation for the score (LLM-based metrics) |
| `threshold` | `number() \| nil` | The threshold used for pass/fail; the integer `1` in strict mode; `nil` for a score-only metric or when unknown |
| `error` | `String.t() \| nil` | Error message when the metric could not produce a score |
| `strict_mode` | `boolean()` | Whether the metric ran in strict mode |
| `flaky` | `boolean()` | Whether the metric is flaky: reported, but never deciding its test case's success |
| `score_breakdown` | `map() \| nil` | Per-component scores of a composite metric (not exported) |
| `skipped` | `boolean()` | Whether the metric was skipped instead of measured |
| `metadata` | `map()` | Additional metric-specific data |
| `evaluation_model` | `String.t() \| nil` | Judge model used by LLM-based metrics |
| `evaluation_cost` | `float() \| nil` | USD cost of the LLM calls; `nil` when no LLM was called or a model is not priced |
| `input_tokens` | `integer() \| nil` | Prompt tokens used by the LLM calls |
| `output_tokens` | `integer() \| nil` | Completion tokens used by the LLM calls |
| `latency_ms` | `integer()` | Time taken for evaluation in milliseconds |

## Creating Results

Results are typically created by metrics, but you can create them manually:

```elixir
alias DeepEvalEx.Result

result = Result.new(
  metric: "CustomMetric",
  score: 0.85,
  threshold: 0.5,
  reason: "The response meets quality criteria."
)

result.score     # => 0.85
result.success   # => true (score >= threshold)
```

## Strict Mode, Score-Only and Flaky Metrics

Every metric accepts deepeval's `BaseMetric` options:

- `strict_mode: true` forces the threshold to the integer `1`, as deepeval's
  metric constructors do, and a score below it becomes the integer `0`.
- `threshold: nil` makes the metric **score-only**: `success` is `nil`
  (deepeval's `is_successful()` returns `None`), the metric neither passes nor
  fails its test case, and the export leaves out its `threshold` and
  `success`.
- `flaky: true` reports the result without letting it decide its test case's
  success, as deepeval's `update_status` ignores flaky metrics.

```elixir
{:ok, result} = Faithfulness.measure(test_case, strict_mode: true)
result.threshold # => 1
result.score     # => 0 (anything below 1 is clamped)

{:ok, result} = Faithfulness.measure(test_case, threshold: nil)
result.success   # => nil
```

`DeepEvalEx.evaluate/3` raises `ArgumentError`, like deepeval's `evaluate()`,
when no non-flaky metric has a threshold.

## Errored vs Failed Results

A **failed** result has a score that misses the threshold. An **errored**
result means the metric never produced a score: an LLM call failed, the test
case was missing required parameters, or the evaluation timed out. This
mirrors deepeval's `MetricData`, where `error` is set and `score` is `None`.

Errored results have:

- `score: nil` and `reason: nil`
- `success: false` (`nil` for a score-only metric, as in deepeval)
- `error` set to a message string
- `threshold` set to the metric's real threshold (its own configuration, the
  run-level `:threshold` option, or the metric's default)

```elixir
result = Result.error("Faithfulness", "Evaluation timed out", threshold: 0.5)

Result.errored?(result)  # => true
result.score             # => nil
result.success           # => false
result.error             # => "Evaluation timed out"
```

`Result.error/3` accepts a string, `{:missing_params, params}` (rendered as
`"Missing required parameters: ..."`) or any other term (inspected). The
evaluator uses it for every error path, so always check `Result.errored?/1`
before reading `score`:

```elixir
cond do
  Result.errored?(result) -> IO.puts("#{result.metric}: ERROR - #{result.error}")
  result.success -> IO.puts("#{result.metric}: PASS")
  true -> IO.puts("#{result.metric}: FAIL (#{result.score})")
end
```

## Understanding Scores

### Higher is Better

Every built-in metric follows the pattern `success = score >= threshold`:
`threshold` is the minimum passing score.

```elixir
# Score 0.8 with threshold 0.5 => success
{:ok, result} = Faithfulness.measure(test_case, threshold: 0.5)
result.score    # => 0.8
result.success  # => true
```

`Hallucination` included: like deepeval 4.3.1, it scores the fraction of
contexts the output agrees with, so a low score means more contradictions.

```elixir
# Score 0.1 with threshold 0.5 => failure (the output contradicts most contexts)
{:ok, result} = Hallucination.measure(test_case, threshold: 0.5)
result.score    # => 0.1
result.success  # => false
```

A custom metric can still pass `success:` to `DeepEvalEx.Result.new/1` when a
lower score is better (see [Custom Metrics](../guides/Custom-Metrics.md)).

## Working with Results

### Check Success

```elixir
if Result.success?(result) do
  IO.puts("Evaluation passed!")
else
  IO.puts("Evaluation failed: #{result.reason}")
end
```

### Check for Errors

```elixir
Result.errored?(result)
# => false for scored results, true when the metric errored
```

### Get Summary

```elixir
Result.summary(result)
# => "Faithfulness: PASS (85.0%) - 4 out of 5 claims are supported."

Result.summary(errored_result)
# => "Faithfulness: ERROR - Evaluation timed out"
```

### String Representation

Results implement `String.Chars`:

```elixir
IO.puts(result)
# => "Faithfulness: PASS (85.0%) - 4 out of 5 claims are supported."
```

### Inspect

Results have a custom `Inspect` implementation:

```elixir
inspect(result)
# => #DeepEvalEx.Result<metric: "Faithfulness", score: 0.85, status: "PASS", threshold: 0.5>

inspect(errored_result)
# => #DeepEvalEx.Result<metric: "Faithfulness", score: nil, status: "ERROR", threshold: 0.5, error: "Evaluation timed out">
```

## Metadata

Metrics include additional data in the `metadata` field:

```elixir
# Faithfulness metadata
result.metadata
# => %{
#   claims: ["claim1", "claim2", "claim3"],
#   truths: ["truth1", "truth2"],
#   verdicts: [
#     %{verdict: :yes, reason: "Supported by truth 1"},
#     %{verdict: :no, reason: "Not found in context"},
#     %{verdict: :borderline, reason: "Partially supported"}
#   ]
# }

# ContextualPrecision metadata
result.metadata
# => %{
#   verdicts: [%{verdict: :yes}, %{verdict: :no}],
#   context_count: 2,
#   relevant_count: 1
# }
```

## Model, Tokens and Cost

Like deepeval's `MetricData` (`evaluationModel`, `evaluationCost`,
`inputTokenCount`, `outputTokenCount`), LLM-based metrics report the judge
model and the summed token usage and cost of every LLM call they made:

```elixir
{:ok, result} = Faithfulness.measure(test_case, adapter: :openai, model: "gpt-4o-mini")

result.evaluation_model  # => "gpt-4o-mini"
result.input_tokens      # => 2_431
result.output_tokens     # => 312
result.evaluation_cost   # => 0.00055185
```

- Metrics that make no LLM call (e.g. `ExactMatch`) leave all four `nil`.
- LLM-based metrics report their configured judge as `evaluation_model` even
  when they made no call, as deepeval sets it when the metric is created.
  `ToolCorrectness` reports its judge too, even without `:available_tools`.
- Errored results keep the judge model and the tokens and cost of the calls
  made before the error, like deepeval's errored `MetricData`.
- Token counts are `nil` when the adapter does not report usage.
- `evaluation_cost` is `nil` when any call's model has no price in
  `DeepEvalEx.LLM.Pricing`; add one with the `:model_pricing` config.

## Example: Processing Results

```elixir
alias DeepEvalEx.{TestCase, Metrics, Result}

test_case = TestCase.new!(
  input: "What is Elixir?",
  actual_output: "Elixir is a functional programming language.",
  retrieval_context: ["Elixir is a functional, concurrent language built on Erlang VM."]
)

result = DeepEvalEx.Evaluator.evaluate_metric(test_case, Metrics.Faithfulness, [])

if Result.errored?(result) do
  raise "Faithfulness errored: #{result.error}"
end

IO.puts("Metric: #{result.metric}")
IO.puts("Score: #{Float.round(result.score * 100, 1)}%")
IO.puts("Passed: #{result.success}")
IO.puts("Threshold: #{result.threshold}")
IO.puts("Latency: #{result.latency_ms}ms")

if result.reason do
  IO.puts("Reason: #{result.reason}")
end

if result.metadata[:verdicts] do
  IO.puts("Verdicts:")
  Enum.each(result.metadata.verdicts, fn v ->
    IO.puts("  - #{v.verdict}: #{v.reason}")
  end)
end
```

## Type Specification

```elixir
@type t :: %DeepEvalEx.Result{
  metric: String.t(),
  score: number() | nil,
  success: boolean() | nil,
  reason: String.t() | nil,
  threshold: number() | nil,
  error: String.t() | nil,
  strict_mode: boolean(),
  flaky: boolean(),
  score_breakdown: map() | nil,
  skipped: boolean(),
  metadata: map() | nil,
  evaluation_model: String.t() | nil,
  evaluation_cost: float() | nil,
  input_tokens: non_neg_integer() | nil,
  output_tokens: non_neg_integer() | nil,
  latency_ms: non_neg_integer() | nil
}
```

## See Also

- [TestCase](TestCase.md) - Input for evaluations
- [Evaluator](Evaluator.md) - Batch evaluation
- [Metrics Overview](../metrics/Overview.md) - Available metrics
