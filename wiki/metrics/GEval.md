# GEval Metric

G-Eval is a flexible LLM-as-judge evaluation framework that uses an LLM to evaluate outputs based on custom criteria.

Based on the paper: [G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment](https://arxiv.org/pdf/2303.16634.pdf)

## When to Use

- Custom evaluation criteria that don't fit predefined metrics
- Subjective quality assessment (helpfulness, tone, clarity)
- Domain-specific evaluation requirements
- When you need explainable scoring with reasoning

## How It Works

1. **Define criteria** - Describe what you want to evaluate
2. **Generate evaluation steps** - LLM creates concrete steps from your criteria
3. **Evaluate** - LLM scores the test case using the steps
4. **Get result** - Normalized score (0-1) with detailed reasoning

## Required Parameters

Configurable via `evaluation_params`:

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt |
| `:actual_output` | The LLM's response |
| `:expected_output` | Ground truth (optional) |
| `:retrieval_context` | Retrieved context (optional) |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.GEval}

# Create a metric
metric = GEval.new(
  name: "Helpfulness",
  criteria: "Determine if the response is helpful and addresses the user's question completely",
  evaluation_params: [:input, :actual_output]
)

# Create a test case
test_case = TestCase.new!(
  input: "How do I make pasta?",
  actual_output: "Boil water, add pasta, cook for 8-10 minutes, drain and serve with sauce."
)

# Evaluate
{:ok, result} = GEval.evaluate(metric, test_case)

result.score   # => 0.85 (normalized 0-1)
result.reason  # => "The response provides clear, actionable steps..."
result.success # => true (score >= threshold)
```

## Options

### Basic Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | string | required | Name for this metric |
| `:criteria` | string | nil | Evaluation criteria description |
| `:evaluation_params` | list | required | Test case parameters to evaluate |
| `:threshold` | float | 0.5 | Pass/fail threshold |

### Advanced Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:evaluation_steps` | list | nil | Pre-defined evaluation steps |
| `:rubric` | list | nil | Scoring rubric with descriptions |
| `:score_range` | tuple | {0, 10} | Min/max score range |
| `:strict_mode` | boolean | false | Binary 0/1 scoring |
| `:model` | tuple/string | default | LLM model to use |

## Pre-defined Evaluation Steps

Skip the step generation by providing your own:

```elixir
metric = GEval.new(
  name: "Code Quality",
  evaluation_params: [:input, :actual_output],
  evaluation_steps: [
    "Check if the code is syntactically correct",
    "Verify the code addresses the requirements",
    "Assess code readability and style",
    "Check for potential bugs or edge cases"
  ]
)
```

## Using a Rubric

Provide explicit scoring guidance:

```elixir
metric = GEval.new(
  name: "Response Quality",
  criteria: "Evaluate the overall quality of the response",
  evaluation_params: [:input, :actual_output],
  rubric: [
    {10, "Perfect response - comprehensive, accurate, well-structured"},
    {8, "Excellent response - minor improvements possible"},
    {6, "Good response - addresses main points but lacks detail"},
    {4, "Acceptable response - partially addresses the question"},
    {2, "Poor response - mostly irrelevant or incorrect"},
    {0, "Unacceptable - does not address the question at all"}
  ]
)
```

## Strict Mode

For binary pass/fail evaluation:

```elixir
metric = GEval.new(
  name: "Factual Accuracy",
  criteria: "The response must be 100% factually accurate",
  evaluation_params: [:input, :actual_output, :expected_output],
  strict_mode: true  # Returns only 0 or 1
)
```

## Custom Score Range

```elixir
metric = GEval.new(
  name: "Rating",
  criteria: "Rate the response on a 1-5 scale",
  evaluation_params: [:input, :actual_output],
  score_range: {1, 5}
)

# Score is still normalized to 0-1 in results
# Raw score available in result.metadata.raw_score
```

## Multiple Evaluation Parameters

Include context for more accurate evaluation:

```elixir
metric = GEval.new(
  name: "RAG Accuracy",
  criteria: "Evaluate if the response accurately uses the provided context",
  evaluation_params: [:input, :actual_output, :retrieval_context]
)

test_case = TestCase.new!(
  input: "What are the company's vacation policies?",
  actual_output: "Employees receive 20 days of PTO per year.",
  retrieval_context: [
    "Section 3.2: All full-time employees receive 20 days of paid time off annually.",
    "Section 3.3: PTO can be carried over up to 5 days per year."
  ]
)
```

## Specifying LLM Model

```elixir
# Use a specific model
metric = GEval.new(
  name: "Test",
  criteria: "...",
  evaluation_params: [:input, :actual_output],
  model: {:openai, "gpt-4o"}  # More capable model
)

# Or override at evaluation time
{:ok, result} = GEval.evaluate(metric, test_case,
  adapter: :anthropic,
  model: "claude-3-opus-20240229"
)
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Helpfulness [GEval]",
  score: 0.85,
  success: true,
  threshold: 0.5,
  reason: "The response provides clear, step-by-step instructions...",
  latency_ms: 1250,
  metadata: %{
    raw_score: 8.5,
    score_range: {0, 10},
    evaluation_steps: ["Step 1: ...", "Step 2: ..."],
    criteria: "Determine if the response is helpful..."
  }
}
```

## Best Practices

### Writing Good Criteria

```elixir
# Good - specific and measurable
criteria: "The response should: 1) directly answer the question, 2) be factually accurate, 3) be concise (under 100 words)"

# Avoid - vague and subjective
criteria: "The response should be good"
```

### Choosing Evaluation Parameters

- Include `:expected_output` when you have ground truth
- Include `:retrieval_context` for RAG evaluation
- Fewer parameters = faster evaluation (fewer tokens)

### Performance Tips

- Use `gpt-4o-mini` for faster, cheaper evaluations
- Pre-define `evaluation_steps` to skip generation step
- Run evaluations concurrently with `evaluate_batch/3`

## Error Handling

```elixir
case GEval.evaluate(metric, test_case) do
  {:ok, result} ->
    IO.puts("Score: #{result.score}")

  {:error, {:missing_params, params}} ->
    IO.puts("Missing: #{inspect(params)}")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error: #{status}")
end
```

## Source

Ported from `deepeval/metrics/g_eval/g_eval.py`

Reference paper: https://arxiv.org/pdf/2303.16634.pdf
