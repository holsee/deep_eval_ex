# Faithfulness Metric

Faithfulness measures whether claims in an LLM's output are supported by the retrieval context. This is essential for RAG (Retrieval-Augmented Generation) evaluation to ensure responses are grounded in retrieved information.

## When to Use

- RAG pipeline evaluation
- Fact-checking LLM outputs against source documents
- Ensuring responses don't hallucinate beyond provided context
- Compliance checking where outputs must be traceable to sources

## How It Works

1. **Extract claims** - Identify factual claims from the actual output
2. **Extract truths** - Identify facts from the retrieval context
3. **Generate verdicts** - For each claim, determine if it's:
   - `yes` - Supported by the context
   - `no` - Contradicts the context
   - `idk` - Cannot be verified (not mentioned in context)
4. **Calculate score** - `(supported claims + idk claims) / total claims`

Note: `idk` verdicts are counted as faithful since they don't contradict the context.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:actual_output` | The LLM's response |
| `:retrieval_context` | List of context documents |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.Faithfulness}

test_case = TestCase.new!(
  input: "What is the company's vacation policy?",
  actual_output: "Employees get 20 days of PTO per year.",
  retrieval_context: [
    "Section 3.2: Full-time employees receive 20 days paid time off annually.",
    "Section 3.3: PTO can be carried over up to 5 days."
  ]
)

{:ok, result} = Faithfulness.measure(test_case)

result.score   # => 1.0 (claim is supported)
result.reason  # => "All claims are supported by the context..."
result.success # => true (score >= threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Pass/fail threshold |
| `:include_reason` | boolean | true | Generate explanation |
| `:truths_extraction_limit` | integer | nil | Max truths per doc |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | All claims supported or unverifiable |
| 0.5 | Half of claims contradict context |
| 0.0 | All claims contradict context |

## Verdict Types

### Yes - Supported

Claim is directly supported by the retrieval context.

```elixir
# Context: "Python is a programming language created by Guido van Rossum"
# Output: "Python was created by Guido van Rossum"
# Verdict: yes
```

### No - Contradicts

Claim directly contradicts information in the context.

```elixir
# Context: "The company was founded in 2010"
# Output: "The company was founded in 1995"
# Verdict: no (score impact: decreases faithfulness)
```

### Idk - Unverifiable

Claim cannot be verified from context (not mentioned).

```elixir
# Context: "The API supports JSON responses"
# Output: "The API also supports XML"
# Verdict: idk (not contradicting, so counted as faithful)
```

## Using Context Alias

You can use `context` as an alias for `retrieval_context`:

```elixir
test_case = TestCase.new!(
  input: "Question",
  actual_output: "Answer",
  context: ["Document 1", "Document 2"]  # Same as retrieval_context
)
```

## Limiting Truth Extraction

For large contexts, limit the number of truths extracted:

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  truths_extraction_limit: 10  # Max 10 truths per document
)
```

## Skipping Reason Generation

For faster evaluation, skip reason generation:

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  include_reason: false
)

result.reason  # => nil
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Faithfulness",
  score: 0.75,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.75 because 3 of 4 claims are supported...",
  latency_ms: 2500,
  metadata: %{
    truths: ["Truth 1", "Truth 2", ...],
    claims: ["Claim 1", "Claim 2", ...],
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "Context says X, not Y"},
      ...
    ],
    truths_extraction_limit: nil
  }
}
```

## Adjusting Threshold

```elixir
# Strict: require all claims to be supported
{:ok, result} = Faithfulness.measure(test_case, threshold: 1.0)

# Lenient: allow some contradictions
{:ok, result} = Faithfulness.measure(test_case, threshold: 0.3)
```

## Specifying LLM Model

```elixir
# Use a specific model
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case Faithfulness.measure(test_case) do
  {:ok, result} ->
    IO.puts("Faithfulness: #{result.score}")

  {:error, {:missing_params, [:retrieval_context]}} ->
    IO.puts("Missing retrieval context")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Best Practices

### Provide Complete Context

Include all relevant documents that the LLM should use:

```elixir
test_case = TestCase.new!(
  input: "What are the return policies?",
  actual_output: "Items can be returned within 30 days for a full refund.",
  retrieval_context: [
    "Returns: Items may be returned within 30 days of purchase.",
    "Refunds: Full refunds are issued for items in original condition.",
    "Exceptions: Electronics have a 14-day return window."
  ]
)
```

### Use with Other RAG Metrics

Combine Faithfulness with other RAG metrics for comprehensive evaluation:

```elixir
alias DeepEvalEx.Metrics.{Faithfulness, AnswerRelevancy, ContextualPrecision}

metrics = [
  Faithfulness,
  AnswerRelevancy,
  ContextualPrecision
]

results = DeepEvalEx.evaluate(test_case, metrics)
```

### Performance Considerations

- Faithfulness makes multiple LLM calls (truths, claims, verdicts, reason)
- Use `gpt-4o-mini` for faster, cheaper evaluations
- Set `include_reason: false` to skip one LLM call
- Use `truths_extraction_limit` for large contexts

## Comparison with Hallucination

| Metric | Measures | Score Meaning |
|--------|----------|---------------|
| Faithfulness | Claims supported by context | Higher = more faithful |
| Hallucination | Unsupported statements | Higher = more hallucinations |

Faithfulness focuses on whether claims are grounded in context, while Hallucination detects fabricated information.

## Source

Ported from `deepeval/metrics/faithfulness/faithfulness.py`
