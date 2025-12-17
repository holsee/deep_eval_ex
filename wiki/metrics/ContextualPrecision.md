# Contextual Precision Metric

Contextual Precision measures how well a retrieval system ranks relevant context nodes higher than irrelevant ones. This is a key metric for evaluating RAG (Retrieval-Augmented Generation) pipelines, particularly the quality of the retrieval component.

## When to Use

- Evaluating RAG retrieval system ranking quality
- Optimizing retrieval algorithms to prioritize relevant documents
- Comparing different retrieval strategies
- Quality assurance for search and recommendation systems
- Tuning re-ranking models

## How It Works

1. **Generate verdicts** - For each retrieval context node, determine if it's:
   - `yes` - Useful in arriving at the expected output
   - `no` - Not useful/irrelevant
2. **Calculate score** - Weighted cumulative precision (Average Precision):
   - For each relevant node at position k: precision@k = relevant_so_far / k
   - Score = sum(precision@k for relevant nodes) / total_relevant_nodes
3. **Higher score is better** - Success when score ≥ threshold

## Why Order Matters

The score rewards having relevant nodes ranked first. The same set of verdicts produces different scores based on ordering:

| Ranking | Score | Explanation |
|---------|-------|-------------|
| [yes, yes, no] | 1.0 | Relevant nodes first |
| [yes, no, yes] | 0.83 | Irrelevant in middle |
| [no, yes, yes] | 0.58 | Irrelevant node first |
| [no, no, yes] | 0.33 | Relevant node last |

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:expected_output` | The expected/ground truth output |
| `:retrieval_context` | List of retrieved context documents (ordered by rank) |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ContextualPrecision}

test_case = TestCase.new!(
  input: "Who won the Nobel Prize in 1921?",
  expected_output: "Einstein won the Nobel Prize in 1921 for the photoelectric effect.",
  retrieval_context: [
    "Einstein won the Nobel Prize in 1921.",
    "The prize was for the photoelectric effect.",
    "There was a cat."
  ]
)

{:ok, result} = ContextualPrecision.measure(test_case)

result.score   # => 1.0 (relevant nodes ranked first)
result.reason  # => "All relevant nodes are ranked at the top..."
result.success # => true (score >= threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Pass/fail threshold |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |

## Understanding the Score Calculation

The score uses weighted cumulative precision, similar to Average Precision in information retrieval:

```
For each relevant node at position k:
  precision@k = (number of relevant nodes so far) / k

Score = sum(precision@k) / total_relevant_nodes
```

### Example Calculation

Given verdicts: [yes, no, yes]

```
Position 1 (yes): precision@1 = 1/1 = 1.0
Position 2 (no):  skip (not relevant)
Position 3 (yes): precision@3 = 2/3 = 0.67

Score = (1.0 + 0.67) / 2 = 0.83
```

## Using Context Alias

You can use `context` as an alias for `retrieval_context`:

```elixir
test_case = TestCase.new!(
  input: "Question",
  expected_output: "Answer",
  context: ["Doc 1", "Doc 2", "Doc 3"]  # Same as retrieval_context
)
```

## Skipping Reason Generation

For faster evaluation, skip reason generation:

```elixir
{:ok, result} = ContextualPrecision.measure(test_case,
  include_reason: false
)

result.reason  # => nil
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Contextual Precision",
  score: 0.83,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.83 because the third node is irrelevant...",
  latency_ms: 1500,
  metadata: %{
    context_count: 3,
    verdicts: [
      %{verdict: :yes, reason: "Contains Nobel Prize info."},
      %{verdict: :no, reason: "Cat is not relevant."},
      %{verdict: :yes, reason: "Contains photoelectric effect info."}
    ]
  }
}
```

## Adjusting Threshold

```elixir
# Strict: require excellent ranking
{:ok, result} = ContextualPrecision.measure(test_case, threshold: 0.9)

# Lenient: allow some ranking issues
{:ok, result} = ContextualPrecision.measure(test_case, threshold: 0.3)
```

## Specifying LLM Model

```elixir
# Use a specific model
{:ok, result} = ContextualPrecision.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = ContextualPrecision.measure(test_case,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case ContextualPrecision.measure(test_case) do
  {:ok, result} ->
    if result.success do
      IO.puts("Good retrieval ranking: #{result.score}")
    else
      IO.puts("Ranking needs improvement: #{result.score}")
    end

  {:error, {:missing_params, params}} ->
    IO.puts("Missing required params: #{inspect(params)}")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Best Practices

### Provide Clear Expected Output

The expected output helps the LLM judge relevance:

```elixir
# Good: specific expected output
test_case = TestCase.new!(
  input: "What is the capital of France?",
  expected_output: "Paris is the capital of France.",
  retrieval_context: [...]
)

# Avoid: vague expected output
test_case = TestCase.new!(
  input: "What is the capital of France?",
  expected_output: "A city in Europe.",  # Too vague
  retrieval_context: [...]
)
```

### Order Matters

The retrieval context list should be in the order returned by your retrieval system (highest ranked first):

```elixir
# Correct: ordered by retrieval rank
retrieval_context: [
  "Most relevant doc (rank 1)",
  "Second most relevant (rank 2)",
  "Third doc (rank 3)"
]
```

### Use with Contextual Recall

Combine with Contextual Recall for comprehensive retrieval evaluation:

```elixir
alias DeepEvalEx.Metrics.{ContextualPrecision, ContextualRecall}

# Precision: Are relevant docs ranked higher?
{:ok, precision} = ContextualPrecision.measure(test_case)

# Recall: Did we retrieve all relevant information?
{:ok, recall} = ContextualRecall.measure(test_case)
```

## Comparison with Related Metrics

| Metric | Focus | Use Case |
|--------|-------|----------|
| Contextual Precision | Ranking quality | Optimize retrieval ordering |
| Contextual Recall | Coverage | Ensure all relevant info retrieved |
| Faithfulness | Grounding | Verify output uses context |

### When to Choose Each

- **Use Contextual Precision** to evaluate if your retrieval system ranks relevant documents first
- **Use Contextual Recall** to evaluate if all relevant information is retrieved
- **Use Faithfulness** to evaluate if the LLM output is grounded in the retrieved context
- **Use all three** for comprehensive RAG evaluation

## Example: Comparing Retrieval Strategies

```elixir
alias DeepEvalEx.{TestCase, Metrics.ContextualPrecision}

base_test = %{
  input: "What are the health benefits of exercise?",
  expected_output: "Exercise improves cardiovascular health and mental well-being."
}

# Strategy A: BM25 retrieval
strategy_a = TestCase.new!(Map.merge(base_test, %{
  retrieval_context: [
    "Exercise strengthens the heart.",
    "Today's weather is sunny.",
    "Physical activity releases endorphins."
  ]
}))

# Strategy B: Semantic search
strategy_b = TestCase.new!(Map.merge(base_test, %{
  retrieval_context: [
    "Exercise strengthens the heart.",
    "Physical activity releases endorphins.",
    "Today's weather is sunny."
  ]
}))

{:ok, result_a} = ContextualPrecision.measure(strategy_a)
{:ok, result_b} = ContextualPrecision.measure(strategy_b)

IO.puts("BM25 score: #{result_a.score}")      # Lower (irrelevant in middle)
IO.puts("Semantic score: #{result_b.score}")  # Higher (relevant first)
```

## Source

Ported from `deepeval/metrics/contextual_precision/contextual_precision.py`
