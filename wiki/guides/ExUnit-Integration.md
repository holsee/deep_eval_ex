# ExUnit Integration

Use DeepEvalEx assertions in your ExUnit tests for CI/CD evaluation.

## Overview

DeepEvalEx provides custom ExUnit assertion macros that make it easy to test LLM outputs against evaluation metrics with detailed failure messages.

## Setup

Add the `use` macro to your test module:

```elixir
defmodule MyApp.LLMTest do
  use ExUnit.Case
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.{TestCase, Metrics}

  # Your tests here
end
```

## Available Assertions

| Macro | Description |
|-------|-------------|
| `assert_passes/2,3` | Assert metric evaluation passes (score >= threshold) |
| `assert_fails/2,3` | Assert metric evaluation fails (score < threshold) |
| `assert_score/3,4` | Assert score is within a specific range |
| `assert_evaluation/2,3` | Assert all metrics pass for a test case |

## `assert_passes/2,3`

Assert that a test case passes a metric evaluation.

```elixir
test "response is faithful to context" do
  test_case = TestCase.new!(
    input: "What is the capital of France?",
    actual_output: "Paris is the capital of France.",
    retrieval_context: ["Paris is the capital city of France."]
  )

  # With default threshold
  assert_passes(test_case, Metrics.Faithfulness)

  # With custom threshold
  assert_passes(test_case, Metrics.Faithfulness, threshold: 0.8)

  # With additional options
  assert_passes(test_case, Metrics.Faithfulness,
    threshold: 0.7,
    adapter: :openai,
    model: "gpt-4o"
  )
end
```

`assert_passes(test_case, metric)` is deepeval's `assert_test(test_case, [metric])`:
the test case is evaluated by `DeepEvalEx.Evaluator` (concurrency, timeouts and
`ignore_errors` / `skip_on_missing_params` included, with `assert_test`'s
`max_concurrent: 100` and `throttle_value: 0` unless you pass them), and it
raises `ArgumentError` when the metric has no threshold or is flaky, as
`assert_test` does.

### Failure Output

When an assertion fails, the message is deepeval's `assert_test` message, with
each field printed as Python prints it:

```
Metrics: Faithfulness (score: 0.4, threshold: 0.5, strict: False, error: None, reason: 2 out of 5 claims are not supported by the context.) failed.
```

## `assert_fails/2,3`

Assert that a test case fails a metric evaluation. Useful for testing edge cases.

```elixir
test "hallucinated response is detected" do
  test_case = TestCase.new!(
    input: "What color is the sky?",
    actual_output: "The sky is green with purple polka dots.",
    context: ["The sky appears blue during the day due to light scattering."]
  )

  # Hallucination should fail: the output agrees with none of the
  # contexts, so the score is low (below the minimum of 0.3)
  assert_fails(test_case, Metrics.Hallucination, threshold: 0.3)
end
```

## `assert_score/3,4`

Assert that the score falls within a specific range.

### Minimum Score

```elixir
test "response has at least 70% relevancy" do
  test_case = TestCase.new!(
    input: "How do I learn Elixir?",
    actual_output: "Read the official guides and practice with projects."
  )

  assert_score(test_case, Metrics.AnswerRelevancy, min: 0.7)
end
```

### Maximum Score

```elixir
test "response is not a verbatim copy of the expected output" do
  test_case = TestCase.new!(
    input: "What is the capital of France?",
    actual_output: "Paris is the capital and largest city of France.",
    expected_output: "Paris"
  )

  assert_score(test_case, Metrics.ExactMatch, max: 0.0)
end
```

### Exact Score

```elixir
test "exact match returns 1.0" do
  test_case = TestCase.new!(
    input: "What is the answer?",
    actual_output: "42",
    expected_output: "42"
  )

  assert_score(test_case, Metrics.ExactMatch, exact: 1.0)
end
```

### Score Range

```elixir
test "score is within expected range" do
  test_case = TestCase.new!(
    input: "Explain quantum physics",
    actual_output: "Quantum physics studies subatomic particles..."
  )

  assert_score(test_case, Metrics.AnswerRelevancy, min: 0.6, max: 0.9)
end
```

### Delta Tolerance

```elixir
# Allow small variance for exact score matching
assert_score(test_case, Metrics.Faithfulness,
  exact: 0.75,
  delta: 0.05  # ± 0.05 tolerance
)
```

## `assert_evaluation/2,3`

Assert that a test case passes multiple metrics.

```elixir
test "RAG response passes all quality checks" do
  test_case = TestCase.new!(
    input: "What are the company benefits?",
    actual_output: "Employees receive health insurance and 20 days PTO.",
    expected_output: "Health insurance, dental, and 20 days paid time off.",
    retrieval_context: [
      "Section 3.1: All employees receive comprehensive health insurance.",
      "Section 3.2: Full-time employees get 20 days paid time off annually."
    ]
  )

  results = assert_evaluation(test_case, [
    Metrics.Faithfulness,
    Metrics.AnswerRelevancy,
    Metrics.ContextualRecall
  ])

  # Returns list of results if all pass
  assert length(results) == 3
end
```

### With Options

```elixir
assert_evaluation(test_case, [
  Metrics.Faithfulness,
  Metrics.Hallucination
],
  threshold: 0.7,
  adapter: :openai,
  model: "gpt-4o-mini"
)
```

### Failure Output

`assert_evaluation(test_case, metrics)` is deepeval's `assert_test(test_case,
metrics)`. The test case fails when a non-flaky metric fails; the message then
lists every errored or unsuccessful metric, flaky and score-only ones included,
in the order given:

```
Metrics: Faithfulness (score: 0.4, threshold: 0.5, strict: False, error: None, reason: Not all claims are supported), Answer Relevancy (score: 0.3, threshold: 0.5, strict: False, error: None, reason: Response contains irrelevant information) failed.
```

### Flaky Metrics and Test Cases

A failing metric marked `flaky` never fails the test case on its own. A test
case marked `flaky: true` does not fail the assertion at all: as deepeval's
`warnings.warn`, a warning is printed instead and the results are returned:

```
warning: Flaky test case failed (no assertion raised): Metrics: Exact Match (score: 0.0, threshold: 1.0, strict: False, error: None, reason: The actual and expected outputs are different.) failed.
```

## Complete Test Example

```elixir
defmodule MyApp.RAGEvaluationTest do
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.{TestCase, Metrics}

  @moduletag :llm_evaluation

  describe "RAG quality" do
    test "faithful responses" do
      test_case = build_test_case(
        "What is our return policy?",
        "You can return items within 30 days for a full refund.",
        ["Policy: Items may be returned within 30 days for full refund."]
      )

      result = assert_passes(test_case, Metrics.Faithfulness, threshold: 0.8)
      assert result.score >= 0.8
    end

    test "relevant answers" do
      test_case = build_test_case(
        "How do I reset my password?",
        "Click 'Forgot Password' on the login page and follow the email instructions."
      )

      assert_score(test_case, Metrics.AnswerRelevancy, min: 0.7)
    end

    test "no hallucinations" do
      test_case = build_test_case(
        "What colors are available?",
        "The product comes in red, blue, and green.",
        ["Available colors: red, blue, green, yellow."]
      )

      # Hallucination scores the fraction of contexts the output agrees
      # with, so higher is better
      assert_score(test_case, Metrics.Hallucination, min: 0.7)
    end

    test "comprehensive RAG evaluation" do
      test_case = build_test_case(
        "What are the shipping options?",
        "We offer standard (5-7 days) and express (2-3 days) shipping.",
        [
          "Shipping: Standard delivery takes 5-7 business days.",
          "Express shipping available for 2-3 day delivery."
        ],
        "Standard shipping (5-7 days) and express shipping (2-3 days) are available."
      )

      assert_evaluation(test_case, [
        Metrics.Faithfulness,
        Metrics.AnswerRelevancy,
        Metrics.ContextualRecall,
        Metrics.ContextualPrecision
      ], threshold: 0.7)
    end
  end

  defp build_test_case(input, output, context \\ nil, expected \\ nil) do
    TestCase.new!(
      input: input,
      actual_output: output,
      retrieval_context: context,
      expected_output: expected
    )
  end
end
```

## CI/CD Integration

### Running Evaluation Tests

```bash
# Run all tests
mix test

# Run only LLM evaluation tests
mix test --only llm_evaluation

# Exclude slow LLM tests in quick CI
mix test --exclude llm_evaluation
```

### Using Mock Adapter for CI

```elixir
defmodule MyApp.RAGTest do
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.LLM.Adapters.Mock

  setup do
    Mock.clear_responses()
    # Set up mock responses for deterministic tests
    Mock.set_schema_response(~r/truths/i, %{"truths" => ["Truth 1"]})
    Mock.set_schema_response(~r/claims/i, %{"claims" => ["Claim 1"]})
    Mock.set_schema_response(~r/verdicts/i, %{"verdicts" => [%{"verdict" => "yes"}]})
    Mock.set_schema_response(~r/reason/i, %{"reason" => "All claims supported."})
    :ok
  end

  test "mocked evaluation passes" do
    test_case = TestCase.new!(
      input: "Q",
      actual_output: "A",
      retrieval_context: ["Context"]
    )

    assert_passes(test_case, Metrics.Faithfulness, adapter: :mock)
  end
end
```

## Error Handling

A metric that cannot produce a score is *errored*, not failed. As in
deepeval's `assert_test`, the error is raised unless `IGNORE_DEEPEVAL_ERRORS`
(or `config :deep_eval_ex, ignore_errors: true`, or the `ignore_errors: true`
option) is set. With it, `assert_passes` and `assert_evaluation` report the
error in deepeval's message, with no score or reason:

```
Metrics: Faithfulness (score: None, threshold: 0.5, strict: False, error: 'retrieval_context' cannot be None for the 'Faithfulness' metric, reason: None) failed.
```

`assert_fails` and `assert_score`, which have no deepeval counterpart, flunk on
an errored metric with their own message instead of a low score:

### Missing Parameters

```
Faithfulness metric errored: 'retrieval_context' cannot be None for the 'Faithfulness' metric

Metric:    Faithfulness
Threshold: 0.5 (50.0%)
Status:    ERROR (no score was produced)
Ensure your TestCase includes all required fields for this metric.
```

### API Errors

```
GEval metric errored: {:api_error, 429, "Rate limit exceeded"}

Metric:    GEval
Threshold: 0.5 (50.0%)
Status:    ERROR (no score was produced)
```

## Best Practices

1. **Use descriptive test names** - Describe what quality aspect you're testing
2. **Set appropriate thresholds** - Start conservative (0.5) and tune based on your needs
3. **Test edge cases** - Use `assert_fails` to verify bad inputs are caught
4. **Mock for CI** - Use Mock adapter for fast, deterministic CI tests
5. **Tag LLM tests** - Use `@moduletag :llm_evaluation` to easily filter tests

## See Also

- [Metrics Overview](../metrics/Overview.md) - Available metrics and requirements
- [Configuration](Configuration.md) - LLM provider setup
- [Telemetry](Telemetry.md) - Monitoring test runs
