# Contextual Recall Metric

Contextual Recall measures whether sentences in the expected output can be attributed to the retrieval context. This evaluates if the retrieved context contains all the information needed to produce the expected answer.

## When to Use

- Evaluating RAG retrieval coverage
- Ensuring retrieved context contains all necessary information
- Identifying gaps in retrieval results
- Quality assurance for knowledge base completeness
- Debugging retrieval failures

## How It Works

1. **Generate verdicts** - For each sentence in expected output, determine if it's:
   - `yes` - Can be attributed to nodes in retrieval context
   - `no` - Cannot be attributed to any context
2. **Calculate score** - (attributed sentences) / (total sentences)
3. **Higher score is better** - Success when score ≥ threshold

## Precision vs Recall

| Metric | Question | Focus |
|--------|----------|-------|
| Contextual Precision | Are retrieved nodes useful? | Ranking quality |
| Contextual Recall | Is expected output covered? | Coverage |

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:expected_output` | The expected/ground truth output |
| `:retrieval_context` | List of retrieved context documents |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ContextualRecall}

test_case = TestCase.new!(
  input: "What is the capital of France?",
  expected_output: "Paris is the capital of France. It is known for the Eiffel Tower.",
  retrieval_context: [
    "Paris is the capital city of France.",
    "The Eiffel Tower is located in Paris."
  ]
)

{:ok, result} = ContextualRecall.measure(test_case)

result.score   # => 1.0 (all sentences attributable)
result.reason  # => "All sentences can be attributed to context nodes..."
result.success # => true (score >= threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Pass/fail threshold |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | All sentences attributable to context |
| 0.5 | Half of sentences attributable |
| 0.0 | No sentences attributable |

## Using Context Alias

You can use `context` as an alias for `retrieval_context`:

```elixir
test_case = TestCase.new!(
  input: "Question",
  expected_output: "Answer with multiple sentences.",
  context: ["Doc 1", "Doc 2"]  # Same as retrieval_context
)
```

## Skipping Reason Generation

For faster evaluation, skip reason generation:

```elixir
{:ok, result} = ContextualRecall.measure(test_case,
  include_reason: false
)

result.reason  # => nil
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Contextual Recall",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.5 because only one of two sentences is attributable...",
  latency_ms: 1500,
  metadata: %{
    sentence_count: 2,
    context_count: 3,
    verdicts: [
      %{verdict: :yes, reason: "Attributed to 1st node: 'Paris is the capital...'"},
      %{verdict: :no, reason: "No context about population."}
    ]
  }
}
```

## Adjusting Threshold

```elixir
# Strict: require full coverage
{:ok, result} = ContextualRecall.measure(test_case, threshold: 1.0)

# Lenient: allow some gaps
{:ok, result} = ContextualRecall.measure(test_case, threshold: 0.3)
```

## Specifying LLM Model

```elixir
# Use a specific model
{:ok, result} = ContextualRecall.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = ContextualRecall.measure(test_case,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case ContextualRecall.measure(test_case) do
  {:ok, result} ->
    if result.success do
      IO.puts("Good retrieval coverage: #{result.score}")
    else
      IO.puts("Missing context - coverage only #{result.score}")
    end

  {:error, {:missing_params, params}} ->
    IO.puts("Missing required params: #{inspect(params)}")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Best Practices

### Write Complete Expected Output

Include all information that should be covered:

```elixir
# Good: complete expected output
test_case = TestCase.new!(
  input: "What are the features of Paris?",
  expected_output: "Paris is the capital of France. It has the Eiffel Tower. The city has a population of about 2 million.",
  retrieval_context: [...]
)

# Each sentence will be checked for attribution
```

### Use with Contextual Precision

Combine both metrics for comprehensive retrieval evaluation:

```elixir
alias DeepEvalEx.Metrics.{ContextualPrecision, ContextualRecall}

# Precision: Are retrieved nodes useful? (ranking)
{:ok, precision} = ContextualPrecision.measure(test_case)

# Recall: Is expected output covered? (coverage)
{:ok, recall} = ContextualRecall.measure(test_case)

# Both metrics complement each other:
# - High precision, low recall: Good ranking but missing documents
# - Low precision, high recall: Complete but noisy retrieval
# - High both: Excellent retrieval
```

### Interpret Low Recall Scores

A low recall score indicates retrieval gaps:

```elixir
{:ok, result} = ContextualRecall.measure(test_case)

if result.score < 0.5 do
  # Check which sentences are not attributable
  unattributed =
    result.metadata.verdicts
    |> Enum.filter(fn v -> v.verdict == :no end)
    |> Enum.map(fn v -> v.reason end)

  IO.puts("Missing information for: #{inspect(unattributed)}")
end
```

## Comparison with Related Metrics

| Metric | Focus | Use Case |
|--------|-------|----------|
| Contextual Recall | Coverage | Ensure all info is retrieved |
| Contextual Precision | Ranking | Optimize retrieval ordering |
| Faithfulness | Grounding | Verify output uses context |

### When to Choose Each

- **Use Contextual Recall** to evaluate if your retrieval system retrieves all necessary information
- **Use Contextual Precision** to evaluate if relevant documents are ranked first
- **Use Faithfulness** to evaluate if the LLM output is grounded in the retrieved context
- **Use all three** for comprehensive RAG evaluation

## Example: Diagnosing Retrieval Gaps

```elixir
alias DeepEvalEx.{TestCase, Metrics.ContextualRecall}

test_case = TestCase.new!(
  input: "Tell me about Einstein's Nobel Prize",
  expected_output: """
  Einstein won the Nobel Prize in Physics in 1921.
  He received it for his explanation of the photoelectric effect.
  The award ceremony was held in Stockholm.
  """,
  retrieval_context: [
    "Albert Einstein won the Nobel Prize in Physics in 1921.",
    "Einstein's work on the photoelectric effect earned him the Nobel Prize."
  ]
)

{:ok, result} = ContextualRecall.measure(test_case)

IO.puts("Contextual Recall: #{result.score}")
# Expected: 0.67 (2 of 3 sentences attributable)

# The verdict reveals missing information:
# - Sentence 1: yes (Nobel Prize in 1921)
# - Sentence 2: yes (photoelectric effect)
# - Sentence 3: no (no context about Stockholm ceremony)
```

## Source

Ported from `deepeval/metrics/contextual_recall/contextual_recall.py`
