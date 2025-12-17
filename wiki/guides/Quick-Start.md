# Quick Start Guide

Get up and running with DeepEvalEx in 5 minutes.

## Prerequisites

- Elixir 1.15+
- An OpenAI API key (or other LLM provider)

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:deep_eval_ex, "~> 0.1.0"}]
end
```

```bash
mix deps.get
```

## Configuration

Set your API key:

```bash
export OPENAI_API_KEY="sk-..."
```

Or in `config/config.exs`:

```elixir
config :deep_eval_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY")
```

## Your First Evaluation

### 1. Simple Exact Match

```elixir
alias DeepEvalEx.{TestCase, Metrics}

# Create a test case
test_case = TestCase.new!(
  input: "What is 2 + 2?",
  actual_output: "4",
  expected_output: "4"
)

# Evaluate with ExactMatch
{:ok, result} = Metrics.ExactMatch.measure(test_case)

IO.puts("Score: #{result.score}")      # => 1.0
IO.puts("Passed: #{result.success}")   # => true
```

### 2. LLM-as-Judge with GEval

```elixir
alias DeepEvalEx.{TestCase, Metrics.GEval}

# Define evaluation criteria
metric = GEval.new(
  name: "Helpfulness",
  criteria: "Is the response helpful and addresses the user's question?",
  evaluation_params: [:input, :actual_output]
)

# Create test case
test_case = TestCase.new!(
  input: "How do I center a div in CSS?",
  actual_output: "Use flexbox: display: flex; justify-content: center; align-items: center;"
)

# Evaluate
{:ok, result} = GEval.evaluate(metric, test_case)

IO.puts("Score: #{result.score}")     # => 0.85
IO.puts("Reason: #{result.reason}")   # => "The response provides a correct and concise solution..."
```

### 3. RAG Evaluation

```elixir
alias DeepEvalEx.{TestCase, Metrics.GEval}

# Evaluate if response is grounded in context
metric = GEval.new(
  name: "Groundedness",
  criteria: "Is the response accurately based on the provided context?",
  evaluation_params: [:input, :actual_output, :retrieval_context]
)

test_case = TestCase.new!(
  input: "What is the company's remote work policy?",
  actual_output: "Employees can work remotely up to 3 days per week.",
  retrieval_context: [
    "Policy 4.2: Full-time employees may work from home up to 3 days per week.",
    "Policy 4.3: Remote work requests must be approved by the direct manager."
  ]
)

{:ok, result} = GEval.evaluate(metric, test_case)
```

## Batch Evaluation

Evaluate multiple test cases concurrently:

```elixir
test_cases = [
  TestCase.new!(input: "Q1", actual_output: "A1", expected_output: "A1"),
  TestCase.new!(input: "Q2", actual_output: "A2", expected_output: "A2"),
  TestCase.new!(input: "Q3", actual_output: "A3", expected_output: "A3")
]

results = DeepEvalEx.evaluate_batch(test_cases, [Metrics.ExactMatch])

# Results is a list of result lists (one per test case)
Enum.each(results, fn [result] ->
  IO.puts("#{result.metric}: #{result.score}")
end)
```

## Using in Tests

```elixir
defmodule MyApp.LLMTest do
  use ExUnit.Case

  alias DeepEvalEx.{TestCase, Metrics}

  test "LLM returns accurate responses" do
    test_case = TestCase.new!(
      input: "What is the capital of France?",
      actual_output: get_llm_response("What is the capital of France?"),
      expected_output: "Paris"
    )

    {:ok, result} = Metrics.ExactMatch.measure(test_case,
      case_sensitive: false
    )

    assert result.success, "Expected pass but got: #{result.reason}"
  end

  test "LLM responses are helpful" do
    metric = Metrics.GEval.new(
      name: "Helpfulness",
      criteria: "The response should be helpful and actionable",
      evaluation_params: [:input, :actual_output],
      threshold: 0.7
    )

    test_case = TestCase.new!(
      input: "How do I learn Elixir?",
      actual_output: get_llm_response("How do I learn Elixir?")
    )

    {:ok, result} = Metrics.GEval.evaluate(metric, test_case)

    assert result.success, """
    Helpfulness score too low: #{result.score}
    Reason: #{result.reason}
    """
  end
end
```

## Next Steps

- [Metrics Overview](../metrics/Overview.md) - Learn about all available metrics
- [GEval Guide](../metrics/GEval.md) - Deep dive into LLM-as-judge evaluation
- [Configuration](Configuration.md) - Advanced configuration options
- [Custom Metrics](Custom-Metrics.md) - Build your own metrics
