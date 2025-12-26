# ADR-0005: Multi-Step Prompting for RAG Metrics

## Status

Accepted

## Date

2024-12-25

## Context

RAG (Retrieval Augmented Generation) metrics like Faithfulness and Hallucination need to evaluate whether an LLM's output is grounded in the retrieved context. This requires:

1. Understanding what claims the LLM made
2. Understanding what facts exist in the context
3. Comparing claims against facts
4. Producing a score

A single-prompt approach ("Is this output faithful to the context? Score 0-1") produces inconsistent, poorly-calibrated scores with no explainability.

## Decision

Implement multi-step prompting for RAG metrics, with each step producing structured intermediate outputs.

**Example: Faithfulness metric**

```
Step 1: Extract claims from actual_output
  → Returns: ["User logged in at 3pm", "Session lasted 2 hours"]

Step 2: Extract truths from retrieval_context
  → Returns: ["Login timestamp: 15:00", "Session duration: 120 minutes"]

Step 3: Generate verdicts comparing claims to truths
  → Returns: [
      {claim: "User logged in at 3pm", verdict: "yes", reason: "Matches login timestamp"},
      {claim: "Session lasted 2 hours", verdict: "yes", reason: "120 min = 2 hours"}
    ]

Step 4: Calculate score
  → Score = supported_claims / total_claims = 2/2 = 1.0
```

## Consequences

### Positive

- **Explainability**: Each step produces inspectable intermediate results
- **Accuracy**: Structured comparison more reliable than holistic scoring
- **Debugging**: Clear visibility into why a score was assigned
- **Consistency**: Deterministic scoring from verdicts (not LLM-generated scores)
- **Alignment with DeepEval**: Matches the Python library's proven approach

### Negative

- **Higher cost**: 2-4 API calls per metric instead of 1
- **Increased latency**: Sequential API calls add up
- **More prompts to maintain**: Each step requires a carefully crafted prompt
- **Token overhead**: Structured outputs include more tokens

### Neutral

- Intermediate results stored in Result.metadata for debugging
- Each step uses structured outputs (JSON schema) for reliability
- Prompt templates can be customized per-metric

## Alternatives Considered

### Single-prompt scoring

- **Rejected**: Produces inconsistent scores without explanation. LLMs struggle to self-score accurately in a single pass.

### Chain-of-thought in single prompt

- **Rejected**: CoT reasoning is helpful but still produces unreliable numeric scores. Structured extraction is more robust.

### Fine-tuned scoring models

- **Rejected**: Requires training data and model hosting. Multi-step prompting works with any capable LLM.

### Embedding similarity

- **Rejected**: Semantic similarity doesn't capture logical entailment. "The sky is blue" and "The sky is not blue" have high similarity but opposite meanings.

## References

- [DeepEval Faithfulness Implementation](https://github.com/confident-ai/deepeval)
- [Chain-of-Thought Prompting](https://arxiv.org/abs/2201.11903)
- [Measuring Hallucination in LLMs](https://arxiv.org/abs/2311.09000)
