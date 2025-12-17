# Answer Relevancy Metric

Answer Relevancy measures whether the statements in an LLM's output are relevant to addressing the input question. This metric evaluates the appropriateness and focus of responses, ensuring the LLM stays on topic.

## When to Use

- Evaluating chatbot and Q&A system responses
- Ensuring LLM outputs address the user's question
- Detecting off-topic or rambling responses
- Quality assurance for customer support AI
- Filtering irrelevant content from LLM outputs

## How It Works

1. **Extract statements** - Identify individual statements from the actual output
2. **Generate verdicts** - For each statement, determine if it's:
   - `yes` - Relevant to addressing the input
   - `no` - Irrelevant to the input
   - `idk` - Ambiguous (supporting information)
3. **Calculate score** - `(yes + idk) / total statements`
4. **Higher score is better** - Success when score ≥ threshold

Note: `idk` verdicts are counted as relevant since they represent supporting information that doesn't detract from the answer.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:actual_output` | The LLM's response |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.AnswerRelevancy}

test_case = TestCase.new!(
  input: "What are the features of the new laptop?",
  actual_output: "The laptop has a Retina display and 12-hour battery life."
)

{:ok, result} = AnswerRelevancy.measure(test_case)

result.score   # => 1.0 (all statements are relevant)
result.reason  # => "All statements directly address the question..."
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
| 1.0 | All statements relevant or supporting |
| 0.5 | Half of statements are irrelevant |
| 0.0 | All statements are irrelevant |

## Verdict Types

### Yes - Relevant

Statement directly addresses the input question.

```elixir
# Input: "What are the features of the new laptop?"
# Statement: "The laptop has a high-resolution Retina display."
# Verdict: yes (directly relevant)
```

### No - Irrelevant

Statement does not address the input question.

```elixir
# Input: "What are the features of the new laptop?"
# Statement: "The weather is nice today."
# Verdict: no (completely off-topic)
```

### Idk - Ambiguous/Supporting

Statement provides context but doesn't directly answer.

```elixir
# Input: "What are the features of the new laptop?"
# Statement: "Our company was founded in 2010."
# Verdict: idk (tangentially related background info)
```

## Skipping Reason Generation

For faster evaluation, skip reason generation:

```elixir
{:ok, result} = AnswerRelevancy.measure(test_case,
  include_reason: false
)

result.reason  # => nil
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Answer Relevancy",
  score: 0.75,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.75 because 3 of 4 statements are relevant...",
  latency_ms: 1800,
  metadata: %{
    statement_count: 4,
    statements: ["Statement 1", "Statement 2", ...],
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "Off-topic statement about weather"},
      ...
    ]
  }
}
```

## Adjusting Threshold

```elixir
# Strict: require all statements to be relevant
{:ok, result} = AnswerRelevancy.measure(test_case, threshold: 1.0)

# Lenient: allow some irrelevant statements
{:ok, result} = AnswerRelevancy.measure(test_case, threshold: 0.3)
```

## Specifying LLM Model

```elixir
# Use a specific model
{:ok, result} = AnswerRelevancy.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = AnswerRelevancy.measure(test_case,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case AnswerRelevancy.measure(test_case) do
  {:ok, result} ->
    if result.success do
      IO.puts("Response is relevant: #{result.score}")
    else
      IO.puts("Too many irrelevant statements: #{result.score}")
    end

  {:error, {:missing_params, params}} ->
    IO.puts("Missing required params: #{inspect(params)}")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Best Practices

### Write Clear, Specific Inputs

Clear inputs help the metric accurately assess relevance:

```elixir
# Good: specific question
test_case = TestCase.new!(
  input: "What is the return policy for electronics?",
  actual_output: "Electronics can be returned within 14 days..."
)

# Avoid: vague inputs make relevance harder to assess
test_case = TestCase.new!(
  input: "Tell me about stuff",
  actual_output: "..."
)
```

### Use with Other Metrics

Combine Answer Relevancy with other metrics for comprehensive evaluation:

```elixir
alias DeepEvalEx.Metrics.{AnswerRelevancy, Faithfulness, Hallucination}

# For RAG applications
metrics = [
  AnswerRelevancy,  # Is the response on-topic?
  Faithfulness,     # Are claims supported by context?
  Hallucination     # Does it contradict context?
]

results = DeepEvalEx.evaluate(test_case, metrics)
```

### Performance Considerations

- Answer Relevancy makes multiple LLM calls (statements, verdicts, reason)
- Use `gpt-4o-mini` for faster, cheaper evaluations
- Set `include_reason: false` to skip one LLM call

## Example: Complete Evaluation

```elixir
alias DeepEvalEx.{TestCase, Metrics.AnswerRelevancy}

# Test case with mixed relevance
test_case = TestCase.new!(
  input: "What programming languages does the API support?",
  actual_output: """
  The API supports Python, JavaScript, and Ruby client libraries.
  Our office is located in San Francisco.
  All libraries are available on GitHub with MIT license.
  We also have a delicious coffee machine in the break room.
  """
)

{:ok, result} = AnswerRelevancy.measure(test_case)

IO.puts("Answer Relevancy Score: #{result.score}")
IO.puts("Success: #{result.success}")
IO.puts("Reason: #{result.reason}")

# Expected output:
# Answer Relevancy Score: 0.5 (2 relevant, 2 irrelevant)
# Success: true (0.5 >= 0.5)
# Reason: The score is 0.5 because while the API languages are addressed,
#         statements about the office location and coffee machine are irrelevant...
```

## Comparison with Other Metrics

| Metric | Focus | Use Case |
|--------|-------|----------|
| Answer Relevancy | Is output on-topic? | General Q&A quality |
| Faithfulness | Are claims supported? | RAG grounding |
| Hallucination | Does output contradict? | Fact verification |

### When to Choose Each

- **Use Answer Relevancy** to ensure responses stay focused on the question
- **Use Faithfulness** when you need to verify claims against source documents
- **Use Hallucination** when detecting contradictions is critical
- **Use all three** for comprehensive RAG evaluation

## Source

Ported from `deepeval/metrics/answer_relevancy/answer_relevancy.py`
