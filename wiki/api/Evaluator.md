# Evaluator

`DeepEvalEx.Evaluator` provides concurrent evaluation of test cases against metrics.

## Overview

The Evaluator leverages BEAM's lightweight processes to run evaluations concurrently, making it efficient for batch processing large numbers of test cases.

## Basic Usage

### Evaluate Multiple Test Cases

```elixir
alias DeepEvalEx.{TestCase, Evaluator, Metrics}

test_cases = [
  TestCase.new!(input: "Q1", actual_output: "A1", expected_output: "A1"),
  TestCase.new!(input: "Q2", actual_output: "A2", expected_output: "A2"),
  TestCase.new!(input: "Q3", actual_output: "A3", expected_output: "A3")
]

metrics = [Metrics.ExactMatch]

results = Evaluator.evaluate(test_cases, metrics)
# => [[%Result{}], [%Result{}], [%Result{}]]
```

### Multiple Metrics Per Test Case

```elixir
metrics = [
  Metrics.ExactMatch,
  Metrics.Faithfulness,
  Metrics.AnswerRelevancy
]

results = Evaluator.evaluate(test_cases, metrics)
# => [
#   [%Result{metric: "ExactMatch"}, %Result{metric: "Faithfulness"}, %Result{metric: "AnswerRelevancy"}],
#   [%Result{metric: "ExactMatch"}, %Result{metric: "Faithfulness"}, %Result{metric: "AnswerRelevancy"}],
#   ...
# ]
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:concurrency` | integer | schedulers * 2 | Maximum concurrent evaluations |
| `:timeout` | integer | 60_000 | Timeout per test case (ms) |
| `:threshold` | float | 0.5 | Default threshold for all metrics |
| `:model` | string | configured | LLM model for LLM-based metrics |
| `:adapter` | atom | configured | LLM adapter to use |

### Controlling Concurrency

```elixir
# Limit concurrent evaluations (useful for rate-limited APIs)
results = Evaluator.evaluate(test_cases, metrics,
  concurrency: 5
)

# Maximum parallelism
results = Evaluator.evaluate(test_cases, metrics,
  concurrency: 50
)
```

### Setting Timeout

```elixir
# Longer timeout for complex evaluations
results = Evaluator.evaluate(test_cases, metrics,
  timeout: 120_000  # 2 minutes
)
```

### Specifying LLM Options

```elixir
results = Evaluator.evaluate(test_cases, metrics,
  adapter: :openai,
  model: "gpt-4o",
  threshold: 0.7
)
```

## Single Test Case Evaluation

### `evaluate_single/3`

Evaluate one test case against all metrics:

```elixir
results = Evaluator.evaluate_single(test_case, metrics, opts)
# => [%Result{}, %Result{}, ...]
```

### `evaluate_metric/3`

Evaluate one test case against one metric:

```elixir
result = Evaluator.evaluate_metric(test_case, Metrics.Faithfulness, opts)
# => %Result{}
```

## Return Value Structure

The `evaluate/3` function returns a list of result lists:

```elixir
results = Evaluator.evaluate(test_cases, metrics)

# results[i] = results for test_cases[i]
# results[i][j] = result for test_cases[i] with metrics[j]

Enum.each(Enum.zip(test_cases, results), fn {test_case, test_results} ->
  IO.puts("Test: #{test_case.input}")
  Enum.each(test_results, fn result ->
    IO.puts("  #{result.metric}: #{result.score}")
  end)
end)
```

## Error Handling

Errors are captured in the result rather than raising:

```elixir
results = Evaluator.evaluate(test_cases, metrics)

Enum.each(List.flatten(results), fn result ->
  if result.success do
    IO.puts("#{result.metric}: PASS")
  else
    IO.puts("#{result.metric}: FAIL - #{result.reason}")
  end
end)
```

### Timeout Handling

```elixir
# If evaluation times out:
result.reason  # => "Evaluation timed out"
result.score   # => 0.0
result.success # => false
```

## Telemetry Events

The Evaluator emits telemetry events:

```elixir
# Batch start
[:deep_eval_ex, :evaluation, :start]
# Measurements: %{test_case_count: 10, metric_count: 3}

# Batch complete
[:deep_eval_ex, :evaluation, :stop]
# Measurements: %{duration: 5000, test_case_count: 10}
```

See [Telemetry Guide](../guides/Telemetry.md) for more details.

## Example: Full Evaluation Pipeline

```elixir
alias DeepEvalEx.{TestCase, Evaluator, Metrics, Result}

# 1. Prepare test cases
test_cases =
  my_test_data
  |> Enum.map(fn %{question: q, answer: a, context: c} ->
    TestCase.new!(
      input: q,
      actual_output: a,
      retrieval_context: c
    )
  end)

# 2. Define metrics
metrics = [
  Metrics.Faithfulness,
  Metrics.AnswerRelevancy,
  Metrics.Hallucination
]

# 3. Run evaluation
results = Evaluator.evaluate(test_cases, metrics,
  concurrency: 10,
  threshold: 0.7,
  model: "gpt-4o-mini"
)

# 4. Analyze results
all_results = List.flatten(results)
pass_count = Enum.count(all_results, & &1.success)
total = length(all_results)

IO.puts("Passed: #{pass_count}/#{total}")

# Group by metric
by_metric = Enum.group_by(all_results, & &1.metric)

Enum.each(by_metric, fn {metric, metric_results} ->
  avg_score = Enum.sum(Enum.map(metric_results, & &1.score)) / length(metric_results)
  IO.puts("#{metric}: avg score #{Float.round(avg_score, 2)}")
end)
```

## See Also

- [TestCase](TestCase.md) - Creating test cases
- [Result](Result.md) - Understanding results
- [Telemetry Guide](../guides/Telemetry.md) - Monitoring evaluations
