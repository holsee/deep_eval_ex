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
| [ConversationalGEval](ConversationalGEval.md) | Criteria-based evaluation of a whole conversation | Custom criteria for multi-turn chatbots |
| [TurnRelevancy](TurnRelevancy.md) | Each assistant turn is relevant to the conversation so far | Multi-turn chatbots that drift off-topic |
| [ConversationCompleteness](ConversationCompleteness.md) | The assistant satisfies every user intention | Multi-turn chatbots that leave requests unmet |
| [KnowledgeRetention](KnowledgeRetention.md) | The assistant remembers what the user told it | Multi-turn chatbots that ask for the same thing twice |
| [RoleAdherence](RoleAdherence.md) | The assistant stays in the character of its `chatbot_role` | Persona and role-play chatbots |
| [GoalAccuracy](GoalAccuracy.md) | The assistant achieves each user goal with a sound, followed plan | Multi-turn agents that must finish tasks |
| [ToolUse](ToolUse.md) | The assistant picks the right tools and calls them with the right arguments | Multi-turn tool-calling agents |

### System One Metrics
Your own questions, answered by a System One model (Jev) with calibrated probabilities; no LLM is called:

| Metric | Purpose | Use Case |
|--------|---------|----------|
| [ConversationalJevEval](ConversationalJevEval.md) | Weighted Noul, Score and Choice questions about a whole conversation | Cheap, deterministic checks of multi-turn chatbots |

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
| [TurnFaithfulness](TurnFaithfulness.md) | Faithfulness of each turn of a conversation | turns' `retrieval_context` |
| [TurnContextualPrecision](TurnContextualPrecision.md) | Retrieval ranking quality, turn by turn | turns' `retrieval_context`, `expected_outcome` |
| [TurnContextualRecall](TurnContextualRecall.md) | Coverage of the expected outcome, turn by turn | turns' `retrieval_context`, `expected_outcome` |
| [TurnContextualRelevancy](TurnContextualRelevancy.md) | Relevance of each turn's retrieved context to the user | turns' `retrieval_context` |

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

### Summarization Metrics
Judge a summary (`actual_output`) against its original text (`input`):

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [Summarization](Summarization.md) | Claims that agree with the original, and the original's key points covered | `input`, `actual_output` |

### Agent Metrics
Evaluate tool-using agents:

| Metric | Purpose | Required Params |
|--------|---------|-----------------|
| [ToolCorrectness](ToolCorrectness.md) | Tools called vs. expected tools | `tools_called`, `expected_tools` |
| [ArgumentCorrectness](ArgumentCorrectness.md) | Whether each tool call's arguments address the input | `input`, `tools_called` |
| [ToolPermission](ToolPermission.md) | Tool calls within an allowlist and denylist (no LLM) | `tools_called` (and `allowed_tools` or `denied_tools`) |
| [TaskCompletion](TaskCompletion.md) | Whether the agent accomplished its task, judged from its trace | `input`, `actual_output` (and the trace) |
| [StepEfficiency](StepEfficiency.md) | Whether the agent took only the steps its task needed, judged from its trace | `input`, `actual_output` (and the trace) |

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

### Custom Prompts
Every LLM-judged metric takes deepeval's `evaluation_template` as the
`:evaluation_template` option: a module implementing the metric's prompt
behaviour (`DeepEvalEx.Prompts.Faithfulness`, ...) that defines only the
templates it changes. The others, System One templates included, fall back
to deepeval's defaults one by one (see `DeepEvalEx.Prompts.EvaluationTemplate`):

```elixir
defmodule MyFaithfulnessTemplate do
  @behaviour DeepEvalEx.Prompts.Faithfulness

  @impl true
  def generate_claims(opts),
    do: "Only extract pricing claims.\n\n" <> DeepEvalEx.Prompts.Faithfulness.generate_claims(opts)
end

Faithfulness.measure(test_case, evaluation_template: MyFaithfulnessTemplate)
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
- **ContextualRelevancy** - Measure how much of the retrieved context is noise

### For Safety
- **Bias** - Catch prejudiced opinions in outputs
- **Toxicity** - Catch insulting, dismissive or threatening outputs
- **PIILeakage** - Catch outputs that expose personal data

### For Prompt Engineering
- **PromptAlignment** - Check outputs follow the prompt's instructions

### For Summaries
- **Summarization** - Check a summary neither contradicts nor pads its original text, and keeps its key points

### For Agents
- **ToolCorrectness** - Check the agent called the right tools
- **ArgumentCorrectness** - Check the agent called its tools with the right arguments
- **ToolPermission** - Check the agent only called the tools it may
- **TaskCompletion** - Check a traced agent finished the job it was given
- **StepEfficiency** - Check a traced agent did not wander, repeat or over-fetch

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
