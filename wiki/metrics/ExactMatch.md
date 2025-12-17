# ExactMatch Metric

A simple, non-LLM metric that checks if the actual output exactly matches the expected output.

## When to Use

- Factual Q&A where exact answers are expected
- Classification tasks
- Structured output validation
- Quick baseline evaluation

## Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `input` | String | The input prompt |
| `actual_output` | String | The LLM's response |
| `expected_output` | String | The expected/ground truth output |

## Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics}

test_case = TestCase.new!(
  input: "What is the capital of France?",
  actual_output: "Paris",
  expected_output: "Paris"
)

{:ok, result} = Metrics.ExactMatch.measure(test_case)

result.score    # => 1.0
result.success  # => true
result.reason   # => "The actual and expected outputs are exact matches."
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 1.0 | Score threshold for pass/fail |
| `:case_sensitive` | boolean | true | Whether comparison is case-sensitive |
| `:normalize_whitespace` | boolean | false | Collapse multiple whitespace to single space |

### Case Insensitive Matching

```elixir
test_case = TestCase.new!(
  input: "Capital of France?",
  actual_output: "PARIS",
  expected_output: "paris"
)

# Case sensitive (default) - fails
{:ok, result} = Metrics.ExactMatch.measure(test_case)
result.score  # => 0.0

# Case insensitive - passes
{:ok, result} = Metrics.ExactMatch.measure(test_case, case_sensitive: false)
result.score  # => 1.0
```

### Whitespace Normalization

```elixir
test_case = TestCase.new!(
  input: "Greeting",
  actual_output: "Hello    World",   # Multiple spaces
  expected_output: "Hello World"      # Single space
)

# Without normalization - fails
{:ok, result} = Metrics.ExactMatch.measure(test_case)
result.score  # => 0.0

# With normalization - passes
{:ok, result} = Metrics.ExactMatch.measure(test_case, normalize_whitespace: true)
result.score  # => 1.0
```

## Score Interpretation

| Score | Meaning |
|-------|---------|
| 1.0 | Exact match (after normalization if enabled) |
| 0.0 | No match |

## Result Metadata

The result includes metadata for debugging:

```elixir
result.metadata
# => %{
#   expected: "Paris",
#   actual: "Paris",
#   case_sensitive: true,
#   normalize_whitespace: false
# }
```

## Limitations

- Binary scoring (1.0 or 0.0) - no partial credit
- Sensitive to formatting differences
- Not suitable for free-form text evaluation

For more flexible evaluation, consider [GEval](GEval.md).

## Source

Ported from `deepeval/metrics/exact_match/exact_match.py`
