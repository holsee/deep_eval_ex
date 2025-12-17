# Result

`DeepEvalEx.Result` represents the result of evaluating a test case against a metric.

## Overview

Every metric evaluation returns a `Result` struct containing the score, success status, and optional reasoning from LLM-based metrics.

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `metric` | `String.t()` | Name of the metric that produced this result |
| `score` | `float()` | Numeric score from 0.0 to 1.0 |
| `success` | `boolean()` | Whether the score meets the threshold |
| `reason` | `String.t()` | Explanation for the score (LLM-based metrics) |
| `threshold` | `float()` | The threshold used for pass/fail |
| `metadata` | `map()` | Additional metric-specific data |
| `evaluation_cost` | `float()` | Cost of LLM calls for this evaluation |
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

## Understanding Scores

### Standard Metrics (Higher is Better)

Most metrics follow the pattern: `success = score >= threshold`

```elixir
# Score 0.8 with threshold 0.5 => success
{:ok, result} = Faithfulness.measure(test_case, threshold: 0.5)
result.score    # => 0.8
result.success  # => true
```

### Inverted Metrics (Lower is Better)

Some metrics like `Hallucination` are inverted: `success = score <= threshold`

```elixir
# Score 0.1 with threshold 0.5 => success (low hallucination)
{:ok, result} = Hallucination.measure(test_case, threshold: 0.5)
result.score    # => 0.1
result.success  # => true
```

## Working with Results

### Check Success

```elixir
if Result.success?(result) do
  IO.puts("Evaluation passed!")
else
  IO.puts("Evaluation failed: #{result.reason}")
end
```

### Get Summary

```elixir
Result.summary(result)
# => "Faithfulness: PASS (85.0%) - 4 out of 5 claims are supported."
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
#     %{verdict: :idk, reason: "Partially supported"}
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

## Example: Processing Results

```elixir
alias DeepEvalEx.{TestCase, Metrics, Result}

test_case = TestCase.new!(
  input: "What is Elixir?",
  actual_output: "Elixir is a functional programming language.",
  retrieval_context: ["Elixir is a functional, concurrent language built on Erlang VM."]
)

{:ok, result} = Metrics.Faithfulness.measure(test_case)

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
  score: float(),
  success: boolean(),
  reason: String.t() | nil,
  threshold: float(),
  metadata: map() | nil,
  evaluation_cost: float() | nil,
  latency_ms: non_neg_integer() | nil
}
```

## See Also

- [TestCase](TestCase.md) - Input for evaluations
- [Evaluator](Evaluator.md) - Batch evaluation
- [Metrics Overview](../metrics/Overview.md) - Available metrics
