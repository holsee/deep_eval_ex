# Metrics Overview

DeepEvalEx provides evaluation metrics to assess LLM outputs across different dimensions.

## Metric Categories

### Non-LLM Metrics
Fast, deterministic metrics that don't require LLM calls:

| Metric | Purpose | Speed |
|--------|---------|-------|
| [ExactMatch](ExactMatch.md) | Exact string comparison | ⚡ Instant |
| [PatternMatch](PatternMatch.md) | Whole output matches a regular expression | ⚡ Instant |
| [JsonCorrectness](JsonCorrectness.md) | Output is JSON matching a JSON Schema (an LLM explains failures) | ⚡ Instant |
| [ToolPermission](ToolPermission.md) | Tool calls within an allow/deny policy | ⚡ Instant |

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
| [Hallucination](Hallucination.md) | Unsupported statements | `context` |
| [AnswerRelevancy](AnswerRelevancy.md) | Response relevance to question | `input`, `actual_output` |
| [ContextualPrecision](ContextualPrecision.md) | Retrieval ranking quality | `retrieval_context`, `expected_output` |
| [ContextualRecall](ContextualRecall.md) | Coverage of ground truth | `retrieval_context`, `expected_output` |
| [ContextualRelevancy](ContextualRelevancy.md) | Relevance of the retrieved context to the input | `input`, `retrieval_context` |

### Safety Metrics
Judge the opinions and statements in an output; higher scores mean safer outputs:

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [Bias](Bias.md) | Gender, political, racial/ethnic and geographical bias | `input`, `actual_output` |
| [Toxicity](Toxicity.md) | Personal attacks, mockery, hate, dismissive statements and threats | `input`, `actual_output` |
| [PIILeakage](PIILeakage.md) | Personally identifiable information and privacy-sensitive data | `input`, `actual_output` |

### Instruction Metrics
Check an output against the prompt it was generated with:

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [PromptAlignment](PromptAlignment.md) | Whether each prompt instruction is followed | `input`, `actual_output` (and `prompt_instructions`) |

### Agent Metrics
Evaluate tool-using agents:

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [ToolCorrectness](ToolCorrectness.md) | Tools called vs. expected tools | `tools_called`, `expected_tools` |
| [ArgumentCorrectness](ArgumentCorrectness.md) | Whether each tool call's arguments address the input | `input`, `tools_called` |
| [ToolPermission](ToolPermission.md) | Tool calls within an allowlist and denylist (no LLM) | `tools_called` (and `allowed_tools` or `denied_tools`) |

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

Every metric also takes deepeval's `BaseMetric` options:

- `strict_mode: true` - the threshold is forced to `1` and a score below it
  becomes `0`
- `threshold: nil` - score-only: `success` is `nil` and the metric never
  decides its test case's success
- `flaky: true` - reported, but never deciding its test case's success

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
- **ContextualRelevancy** - Measure how much of the retrieved context is noise

### For Safety
- **Bias** - Catch prejudiced opinions in outputs
- **Toxicity** - Catch insulting, dismissive or threatening outputs
- **PIILeakage** - Catch outputs that expose personal data

### For Prompt Engineering
- **PromptAlignment** - Check outputs follow the prompt's instructions

### For Agents
- **ToolCorrectness** - Check the agent called the right tools
- **ArgumentCorrectness** - Check the agent called its tools with the right arguments
- **ToolPermission** - Check the agent only called the tools it may

### For Exact Matching
- **ExactMatch** - When output must exactly match expected
- **PatternMatch** - When output must follow a format (IDs, dates, labels)
- **JsonCorrectness** - When output must be JSON of a given shape (structured output, tool arguments)

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

{:ok, evaluation} = DeepEvalEx.evaluate([test_case], metrics)
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
