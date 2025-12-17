# Custom Metrics

Build your own evaluation metrics for DeepEvalEx.

## Overview

DeepEvalEx provides a `BaseMetric` behaviour that you can implement to create custom metrics. Custom metrics integrate seamlessly with the Evaluator, telemetry, and all other framework features.

## Quick Start

```elixir
defmodule MyApp.Metrics.Brevity do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  @impl true
  def metric_name, do: "Brevity"

  @impl true
  def required_params, do: [:actual_output]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    max_words = Keyword.get(opts, :max_words, 100)

    word_count = test_case.actual_output |> String.split() |> length()
    score = min(1.0, max_words / max(word_count, 1))

    {:ok, DeepEvalEx.Result.new(
      metric: metric_name(),
      score: score,
      threshold: threshold,
      reason: "Response has #{word_count} words (target: ≤#{max_words})"
    )}
  end
end
```

## BaseMetric Behaviour

### Required Callbacks

| Callback | Description |
|----------|-------------|
| `metric_name/0` | Returns the metric name string |
| `required_params/0` | Returns list of required TestCase fields |
| `do_measure/2` | Implements the evaluation logic |

### What `use BaseMetric` Provides

- `measure/2` wrapper with validation and telemetry
- `validate_test_case/1` function
- `default_threshold/0` function
- Automatic telemetry instrumentation

## Implementing `do_measure/2`

The `do_measure/2` function receives the validated test case and options:

```elixir
def do_measure(test_case, opts) do
  # 1. Extract options
  threshold = Keyword.get(opts, :threshold, default_threshold())
  include_reason = Keyword.get(opts, :include_reason, true)

  # 2. Perform evaluation
  score = evaluate(test_case)

  # 3. Generate reason (optional)
  reason = if include_reason, do: generate_reason(test_case, score), else: nil

  # 4. Return result
  {:ok, DeepEvalEx.Result.new(
    metric: metric_name(),
    score: score,
    threshold: threshold,
    reason: reason,
    metadata: %{custom_data: "..."}
  )}
end
```

## LLM-Based Metrics

For metrics that use LLM-as-judge:

```elixir
defmodule MyApp.Metrics.Politeness do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.7

  alias DeepEvalEx.LLM.Adapter

  @impl true
  def metric_name, do: "Politeness"

  @impl true
  def required_params, do: [:actual_output]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())

    prompt = """
    Rate the politeness of this response on a scale of 0.0 to 1.0.

    Response: #{test_case.actual_output}

    Consider: greeting, tone, respectfulness, and professional language.
    """

    schema = %{
      "type" => "object",
      "properties" => %{
        "score" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "reason" => %{"type" => "string"}
      },
      "required" => ["score", "reason"]
    }

    case Adapter.generate_with_schema(prompt, schema, opts) do
      {:ok, %{"score" => score, "reason" => reason}} ->
        {:ok, DeepEvalEx.Result.new(
          metric: metric_name(),
          score: score,
          threshold: threshold,
          reason: reason
        )}

      {:error, _} = error ->
        error
    end
  end
end
```

## Multi-Step Metrics

For complex metrics with multiple LLM calls:

```elixir
defmodule MyApp.Metrics.FactAccuracy do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.8

  alias DeepEvalEx.LLM.Adapter

  @impl true
  def metric_name, do: "Fact Accuracy"

  @impl true
  def required_params, do: [:actual_output, :retrieval_context]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())

    with {:ok, facts} <- extract_facts(test_case.actual_output, opts),
         {:ok, verdicts} <- verify_facts(facts, test_case.retrieval_context, opts) do

      correct_count = Enum.count(verdicts, fn v -> v.correct end)
      score = if length(verdicts) > 0, do: correct_count / length(verdicts), else: 1.0

      {:ok, DeepEvalEx.Result.new(
        metric: metric_name(),
        score: score,
        threshold: threshold,
        reason: "#{correct_count}/#{length(verdicts)} facts verified",
        metadata: %{facts: facts, verdicts: verdicts}
      )}
    end
  end

  defp extract_facts(output, opts) do
    prompt = "Extract factual claims from: #{output}"
    schema = %{"type" => "object", "properties" => %{"facts" => %{"type" => "array", "items" => %{"type" => "string"}}}}

    case Adapter.generate_with_schema(prompt, schema, opts) do
      {:ok, %{"facts" => facts}} -> {:ok, facts}
      error -> error
    end
  end

  defp verify_facts(facts, context, opts) do
    prompt = """
    Verify each fact against the context.
    Facts: #{inspect(facts)}
    Context: #{Enum.join(context, "\n")}
    """
    schema = %{
      "type" => "object",
      "properties" => %{
        "verdicts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "fact" => %{"type" => "string"},
              "correct" => %{"type" => "boolean"},
              "reason" => %{"type" => "string"}
            }
          }
        }
      }
    }

    case Adapter.generate_with_schema(prompt, schema, opts) do
      {:ok, %{"verdicts" => verdicts}} ->
        {:ok, Enum.map(verdicts, fn v ->
          %{fact: v["fact"], correct: v["correct"], reason: v["reason"]}
        end)}
      error -> error
    end
  end
end
```

## Non-LLM Metrics

For metrics that don't need LLM calls:

```elixir
defmodule MyApp.Metrics.ResponseLength do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  @impl true
  def metric_name, do: "Response Length"

  @impl true
  def required_params, do: [:actual_output]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    min_chars = Keyword.get(opts, :min_chars, 50)
    max_chars = Keyword.get(opts, :max_chars, 500)

    char_count = String.length(test_case.actual_output)

    score = cond do
      char_count < min_chars -> char_count / min_chars
      char_count > max_chars -> max_chars / char_count
      true -> 1.0
    end

    {:ok, DeepEvalEx.Result.new(
      metric: metric_name(),
      score: score,
      threshold: threshold,
      reason: "#{char_count} characters (target: #{min_chars}-#{max_chars})",
      metadata: %{char_count: char_count, min: min_chars, max: max_chars}
    )}
  end
end
```

## Inverted Metrics (Lower is Better)

For metrics where lower scores are better (like Hallucination):

```elixir
defmodule MyApp.Metrics.Verbosity do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.3

  @impl true
  def metric_name, do: "Verbosity"

  @impl true
  def required_params, do: [:actual_output]

  def do_measure(test_case, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())

    # Higher word count = higher verbosity score
    word_count = test_case.actual_output |> String.split() |> length()
    score = min(1.0, word_count / 200)  # Normalized to 200 words = 1.0

    # Invert success: success when score <= threshold
    {:ok, DeepEvalEx.Result.new(
      metric: metric_name(),
      score: score,
      threshold: threshold,
      success: score <= threshold,  # Explicit success override
      reason: "Verbosity score: #{Float.round(score, 2)} (#{word_count} words)"
    )}
  end
end
```

## Using Custom Metrics

```elixir
# Single evaluation
{:ok, result} = MyApp.Metrics.Brevity.measure(test_case, max_words: 50)

# With Evaluator
results = DeepEvalEx.Evaluator.evaluate(
  test_cases,
  [MyApp.Metrics.Brevity, MyApp.Metrics.Politeness],
  threshold: 0.7
)
```

## Testing Custom Metrics

```elixir
defmodule MyApp.Metrics.BrevityTest do
  use ExUnit.Case

  alias MyApp.Metrics.Brevity
  alias DeepEvalEx.TestCase

  test "short responses score high" do
    test_case = TestCase.new!(
      input: "What is 2+2?",
      actual_output: "4"
    )

    {:ok, result} = Brevity.measure(test_case, max_words: 10)
    assert result.score == 1.0
    assert result.success
  end

  test "long responses score low" do
    test_case = TestCase.new!(
      input: "Explain quantum physics",
      actual_output: String.duplicate("word ", 200)
    )

    {:ok, result} = Brevity.measure(test_case, max_words: 50)
    assert result.score < 0.5
  end
end
```

## Best Practices

1. **Use structured outputs** - Always use `generate_with_schema` for predictable LLM responses
2. **Include metadata** - Store intermediate results for debugging
3. **Handle errors** - Return `{:error, reason}` for recoverable failures
4. **Document options** - List custom options in moduledoc
5. **Set sensible defaults** - Use `default_threshold` option in `use` macro

## See Also

- [BaseMetric Source](https://github.com/...) - Implementation details
- [Metrics Overview](../metrics/Overview.md) - Built-in metrics
- [Custom LLM Adapters](Custom-LLM-Adapters.md) - Custom LLM providers
