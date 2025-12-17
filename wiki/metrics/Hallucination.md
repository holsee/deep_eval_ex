# Hallucination Metric

Hallucination measures whether an LLM's output contradicts the provided context. Unlike Faithfulness which extracts individual claims, Hallucination directly compares the entire output against each context item to detect contradictions.

## When to Use

- RAG pipeline evaluation when detecting factual contradictions is critical
- Scenarios where you need a simpler, faster evaluation than Faithfulness
- When context items represent authoritative sources that must not be contradicted
- Quality assurance for customer-facing AI responses

## How It Works

1. **Generate verdicts** - For each context, determine if the output:
   - `yes` - Agrees with the context (factual alignment)
   - `no` - Contradicts the context (hallucination)
2. **Calculate score** - `(contradictions) / (total contexts)`
3. **Lower score is better** - Success when score ≤ threshold

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:actual_output` | The LLM's response |
| `:context` | List of context documents |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.Hallucination}

test_case = TestCase.new!(
  input: "What year did Einstein win the Nobel Prize?",
  actual_output: "Einstein won the Nobel Prize in 1969.",
  context: [
    "Einstein won the Nobel Prize in 1921.",
    "Einstein won it for his discovery of the photoelectric effect."
  ]
)

{:ok, result} = Hallucination.measure(test_case)

result.score   # => 0.5 (1 contradiction out of 2 contexts)
result.reason  # => "The score is 0.5 because one of two contexts was contradicted..."
result.success # => true (score <= threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Pass/fail threshold (lower is better) |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 0.0 | No contradictions (best) |
| 0.5 | Half of contexts contradict |
| 1.0 | All contexts contradict (worst) |

**Important:** Unlike most metrics, a lower Hallucination score is better. A score of 0.0 means the output agrees with all contexts.

## Verdict Types

### Yes - Agrees

Output aligns with the context information.

```elixir
# Context: "Einstein won the Nobel Prize in Physics."
# Output: "Einstein was awarded the Nobel Prize for physics."
# Verdict: yes (no hallucination)
```

### No - Contradicts

Output contradicts information in the context.

```elixir
# Context: "Einstein won the Nobel Prize in 1921."
# Output: "Einstein won the Nobel Prize in 1969."
# Verdict: no (hallucination detected)
```

## Using Context Alias

You can use `retrieval_context` as an alias for `context`:

```elixir
test_case = TestCase.new!(
  input: "Question",
  actual_output: "Answer",
  retrieval_context: ["Document 1", "Document 2"]  # Same as context
)
```

## Skipping Reason Generation

For faster evaluation, skip reason generation:

```elixir
{:ok, result} = Hallucination.measure(test_case,
  include_reason: false
)

result.reason  # => nil
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Hallucination",
  score: 0.5,
  success: true,          # Note: success when score <= threshold
  threshold: 0.5,
  reason: "The score is 0.5 because one of two contexts was contradicted...",
  latency_ms: 1500,
  metadata: %{
    context_count: 2,
    verdicts: [
      %{verdict: :yes, reason: "The output agrees with context about..."},
      %{verdict: :no, reason: "The output says X, but context says Y"}
    ]
  }
}
```

## Adjusting Threshold

```elixir
# Strict: no hallucinations allowed
{:ok, result} = Hallucination.measure(test_case, threshold: 0.0)

# Lenient: allow some contradictions
{:ok, result} = Hallucination.measure(test_case, threshold: 0.7)
```

## Specifying LLM Model

```elixir
# Use a specific model
{:ok, result} = Hallucination.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = Hallucination.measure(test_case,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case Hallucination.measure(test_case) do
  {:ok, result} ->
    if result.success do
      IO.puts("No significant hallucinations detected")
    else
      IO.puts("Hallucination score too high: #{result.score}")
    end

  {:error, {:missing_params, [:context]}} ->
    IO.puts("Missing context")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Best Practices

### Provide Authoritative Context

Include contexts that represent ground truth:

```elixir
test_case = TestCase.new!(
  input: "What are the product specifications?",
  actual_output: "The laptop has 16GB RAM and a 256GB SSD.",
  context: [
    "Product spec: 16GB DDR4 RAM",
    "Storage: 512GB NVMe SSD"  # Note: this will detect the contradiction
  ]
)
```

### Use with Faithfulness for Complete Coverage

```elixir
alias DeepEvalEx.Metrics.{Faithfulness, Hallucination}

# Faithfulness: Are claims supported?
{:ok, faithfulness_result} = Faithfulness.measure(test_case)

# Hallucination: Does output contradict context?
{:ok, hallucination_result} = Hallucination.measure(test_case)
```

### Performance Considerations

- Hallucination makes fewer LLM calls than Faithfulness
- Use `gpt-4o-mini` for faster, cheaper evaluations
- Set `include_reason: false` to skip reason generation

## Comparison with Faithfulness

| Aspect | Hallucination | Faithfulness |
|--------|---------------|--------------|
| Focus | Detects contradictions | Verifies claim support |
| Score interpretation | Lower is better | Higher is better |
| LLM calls | Fewer (verdicts + reason) | More (truths, claims, verdicts, reason) |
| Verdicts | yes/no only | yes/no/idk |
| Best for | Quick contradiction check | Detailed claim analysis |

### When to Choose Each

- **Use Hallucination** when you need a faster, simpler check for contradictions
- **Use Faithfulness** when you need detailed claim-by-claim analysis
- **Use both** for comprehensive RAG evaluation

## Example: Complete Evaluation

```elixir
alias DeepEvalEx.{TestCase, Metrics.Hallucination}

# Test case with potential hallucination
test_case = TestCase.new!(
  input: "Tell me about Einstein's Nobel Prize.",
  actual_output: """
  Einstein won the Nobel Prize in Physics in 1969 for his work on
  the photoelectric effect. This groundbreaking discovery revolutionized
  our understanding of quantum mechanics.
  """,
  context: [
    "Albert Einstein won the Nobel Prize in Physics in 1921.",
    "Einstein received the prize for his explanation of the photoelectric effect.",
    "The photoelectric effect demonstrated the quantum nature of light."
  ]
)

{:ok, result} = Hallucination.measure(test_case)

IO.puts("Hallucination Score: #{result.score}")
IO.puts("Success: #{result.success}")
IO.puts("Reason: #{result.reason}")

# Expected output:
# Hallucination Score: 0.333... (1 contradiction out of 3)
# Success: true (0.33 <= 0.5)
# Reason: The output contradicts the year 1921 by stating 1969...
```

## Source

Ported from `deepeval/metrics/hallucination/hallucination.py`
