# Metrics Overview

DeepEvalEx provides evaluation metrics to assess LLM outputs across different dimensions.

## Metric Categories

### Non-LLM Metrics
Fast, deterministic metrics that don't require LLM calls:

| Metric | Purpose | Speed |
|--------|---------|-------|
| [ExactMatch](ExactMatch.md) | Exact string comparison | ⚡ Instant |

### LLM-as-Judge Metrics
Use an LLM to evaluate outputs based on criteria:

| Metric | Purpose | Use Case |
|--------|---------|----------|
| [GEval](GEval.md) | Flexible criteria-based evaluation | Custom evaluation criteria |

### RAG Metrics
Evaluate Retrieval-Augmented Generation pipelines:

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [Faithfulness](Faithfulness.md) | Claims supported by context | `retrieval_context` |
| [Hallucination](Hallucination.md) | Unsupported statements | `retrieval_context` |
| [AnswerRelevancy](AnswerRelevancy.md) | Response relevance to question | `input`, `actual_output` |
| [ContextualPrecision](ContextualPrecision.md) | Retrieval ranking quality | `retrieval_context`, `expected_output` |
| [ContextualRecall](ContextualRecall.md) | Coverage of ground truth | `retrieval_context`, `expected_output` |

## Common Parameters

All metrics share these concepts:

### Test Case
```elixir
%DeepEvalEx.TestCase{
  input: "User question or prompt",
  actual_output: "LLM's response",
  expected_output: "Ground truth (optional)",
  retrieval_context: ["Retrieved chunk 1", "Retrieved chunk 2"]
}
```

### Threshold
Score threshold for pass/fail determination (0.0 - 1.0):

```elixir
{:ok, result} = Metric.measure(test_case, threshold: 0.7)
result.success  # true if score >= 0.7
```

### Result
```elixir
%DeepEvalEx.Result{
  metric: "MetricName",
  score: 0.85,           # 0.0 - 1.0
  success: true,         # score >= threshold
  reason: "Explanation", # From LLM-based metrics
  threshold: 0.5,
  latency_ms: 1250
}
```

## Choosing Metrics

### For General Quality
- **GEval** - Define custom criteria (accuracy, helpfulness, tone)

### For RAG Applications
- **Faithfulness** - Ensure answers are grounded in retrieved context
- **Hallucination** - Detect fabricated information
- **ContextualPrecision/Recall** - Evaluate retrieval quality

### For Exact Matching
- **ExactMatch** - When output must exactly match expected

## Combining Metrics

Evaluate with multiple metrics:

```elixir
metrics = [
  DeepEvalEx.Metrics.ExactMatch,
  DeepEvalEx.Metrics.GEval.new(
    name: "Helpfulness",
    criteria: "Is the response helpful?",
    evaluation_params: [:input, :actual_output]
  )
]

results = DeepEvalEx.evaluate_batch([test_case], metrics)
```

## Performance Considerations

| Metric Type | Latency | Cost |
|-------------|---------|------|
| Non-LLM | < 1ms | Free |
| LLM-based | 1-5s | Per-token |

For high-volume evaluation, consider:
- Using faster models (`gpt-4o-mini` vs `gpt-4o`)
- Concurrent evaluation (default: schedulers × 2)
- Caching results for identical inputs
