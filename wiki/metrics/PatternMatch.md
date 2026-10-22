# PatternMatch Metric

A non-LLM metric that checks that the whole actual output matches a regular expression. It calls no judge and is fully deterministic.

## When to Use

- Outputs with a fixed format: order IDs, phone numbers, dates, ISO codes
- Classifiers that must answer with one of a few labels (`"yes|no|unsure"`)
- Guarding structured output before a stricter parser sees it
- Cheap CI gates that need no API key

## How It Works

1. **Trim** the pattern and the actual output
2. **Full match** - the pattern must match **all** of the output, as Python's `re.fullmatch`: it is anchored as `\A(?:pattern)\z`, so every alternative of `"yes|maybe"` is anchored, and `"\d{3}"` does not match `"1234"`
3. **Score** - `1.0` for a full match, else `0.0`

Like Python's `str` patterns, the pattern is Unicode-aware: `\w`, `\d`, `\s` and `\b` match beyond ASCII (`\w+` matches `"café"`). Patterns are compiled by PCRE (see Elixir's `Regex`), whose syntax is close to Python's `re` but not identical; for instance Python's end-of-string `\Z` is PCRE's `\z`.

## Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `input` | String | The input prompt |
| `actual_output` | String | The LLM's response |

## Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.PatternMatch}

test_case = TestCase.new!(
  input: "What is the store's phone number?",
  actual_output: "555-1234"
)

{:ok, result} = PatternMatch.measure(test_case, pattern: ~S"\d{3}-\d{4}")

result.score   # => 1.0
result.success # => true
result.reason  # => "The actual output fully matches the pattern."
```

A partial match is not enough:

```elixir
test_case = TestCase.new!(input: "Phone?", actual_output: "Call 555-1234")

{:ok, result} = PatternMatch.measure(test_case, pattern: ~S"\d{3}-\d{4}")
result.score  # => 0.0
result.reason # => "The actual output does not match the pattern."
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:pattern` | string | required | The regular expression the whole output must match |
| `:ignore_case` | boolean | false | Match case-insensitively |
| `:threshold` | float | 1.0 | Score threshold for pass/fail (the float `1.0`, as in deepeval) |
| `:verbose_mode` | boolean | false | Compute and print the verbose logs; as in deepeval, there are none otherwise |

A missing pattern raises `ArgumentError`, and so does an invalid one, as deepeval's constructor raises `ValueError`:

```elixir
PatternMatch.new(pattern: "(unclosed")
# ** (ArgumentError) Invalid regex pattern: (unclosed — missing closing parenthesis at position 9
```

## As a Configured Metric

The pattern belongs to the metric, as in deepeval's `PatternMatchMetric(pattern=...)`. To evaluate with other metrics, or two patterns at once, build the metric with `new/1`:

```elixir
metrics = [
  PatternMatch.new(pattern: "yes|no", ignore_case: true),
  PatternMatch.new(pattern: ~S"[A-Z]{3}-\d{6}")
]

DeepEvalEx.evaluate(test_cases, metrics)
```

## Score Interpretation

| Score | Meaning |
|-------|---------|
| 1.0 | The whole output matches the pattern |
| 0.0 | It does not |

Results are named `"Pattern Match"`, matching deepeval's metric name.

## Eval Modes

Like deepeval's, the metric ignores `:eval_mode`: it measures the same way under `:hybrid` and `:system_one`, and builds and calls no System One model.

## Result Metadata

```elixir
result.metadata
# => %{pattern: "\\d{3}-\\d{4}", ignore_case: false}
```

## Source

Ported from `deepeval/metrics/pattern_match/pattern_match.py`
