# DeepEvalEx Wiki

Welcome to the DeepEvalEx documentation. DeepEvalEx is a pure Elixir LLM evaluation framework, ported from [DeepEval](https://github.com/confident-ai/deepeval).

## Quick Navigation

### Getting Started
- [Installation](guides/Installation.md)
- [Quick Start](guides/Quick-Start.md)
- [Configuration](guides/Configuration.md)

### Metrics
- [Overview](metrics/Overview.md)
- [ExactMatch](metrics/ExactMatch.md)
- [PatternMatch](metrics/PatternMatch.md) - Regular expression full match
- [JsonCorrectness](metrics/JsonCorrectness.md) - JSON output against a schema
- [GEval](metrics/GEval.md) - Flexible LLM-as-judge evaluation
- [Faithfulness](metrics/Faithfulness.md) - RAG context verification
- [Hallucination](metrics/Hallucination.md) - Unsupported claim detection
- [AnswerRelevancy](metrics/AnswerRelevancy.md)
- [ContextualPrecision](metrics/ContextualPrecision.md)
- [ContextualRecall](metrics/ContextualRecall.md)
- [ContextualRelevancy](metrics/ContextualRelevancy.md)
- [Bias](metrics/Bias.md) - Bias in the output's opinions
- [Toxicity](metrics/Toxicity.md) - Toxicity in the output's opinions
- [PIILeakage](metrics/PIILeakage.md) - Personal data in the output
- [PromptAlignment](metrics/PromptAlignment.md) - Following the prompt's instructions
- [Summarization](metrics/Summarization.md) - Summary alignment and coverage
- [ToolCorrectness](metrics/ToolCorrectness.md) - Agent tool call evaluation
- [ArgumentCorrectness](metrics/ArgumentCorrectness.md) - Agent tool call arguments
- [ToolPermission](metrics/ToolPermission.md) - Agent tool calls against a permission policy

### API Reference
- [TestCase](api/TestCase.md)
- [Result](api/Result.md)
- [EvaluationResult](api/EvaluationResult.md) - what `evaluate/3` returns
- [Evaluator](api/Evaluator.md)
- [TestRun](api/TestRun.md) - deepeval-compatible test run export and import
- [LLM Adapters](api/LLM-Adapters.md)

### Testing
- [ExUnit Integration](guides/ExUnit-Integration.md) - Test assertions for CI/CD

### Advanced
- [Custom Metrics](guides/Custom-Metrics.md)
- [Custom LLM Adapters](guides/Custom-LLM-Adapters.md)
- [Telemetry & Observability](guides/Telemetry.md)
- [Phoenix LiveView Integration](guides/Phoenix-Integration.md) (planned)

## Attribution

This project is a derivative work of [DeepEval](https://github.com/confident-ai/deepeval) by [Confident AI](https://confident-ai.com), licensed under Apache 2.0.
