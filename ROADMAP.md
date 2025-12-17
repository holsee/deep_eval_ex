# DeepEvalEx Roadmap

A pure Elixir port of [DeepEval](https://github.com/confident-ai/deepeval) for LLM evaluation.

---

## Overview

Port DeepEval's core LLM evaluation functionality to idiomatic Elixir, targeting an MVP with 7 core metrics and Phoenix/LiveView integration for real-time results display.

**Source**: [DeepEval](https://github.com/confident-ai/deepeval) by Confident AI (~464 Python files, 50+ metrics, 11 LLM providers)

**Target**: Pure Elixir library with Phoenix/LiveView components

---

## MVP Scope

### Core Metrics

| Metric | Purpose | Status |
|--------|---------|--------|
| **ExactMatch** | Simple string comparison | Done |
| **GEval** | Flexible criteria-based evaluation | Done |
| **Faithfulness** | RAG: claims supported by context | Done |
| **Hallucination** | Detects unsupported statements | Planned |
| **AnswerRelevancy** | Response relevance to question | Planned |
| **ContextualPrecision** | RAG: context ranking quality | Planned |
| **ContextualRecall** | RAG: coverage of ground truth | Planned |

### Out of MVP Scope

- Conversational metrics (multi-turn)
- Agentic metrics (tool use, task completion)
- Benchmarks (MMLU, GSM8K, etc.)
- Red teaming
- Confident AI cloud sync

---

## Phase 1: Foundation

**Status: Complete**

- [x] Create Mix project with dependencies
- [x] Configure deps: `req`, `jason`, `ecto`, `nimble_options`, `telemetry`
- [x] Set up telemetry events structure
- [x] Configure ExUnit for testing
- [x] Core data structures (`TestCase`, `Result`, `ToolCall`)
- [x] LLM Adapter behaviour
- [x] OpenAI adapter with structured outputs
- [x] Mock adapter for testing
- [x] Credo + Dialyzer compliance

---

## Phase 2: Core Metrics

**Status: In Progress**

### Completed

- [x] **ExactMatch** - Simple string comparison, validates structure
- [x] **GEval** - LLM-as-judge with custom criteria, rubrics, evaluation steps
- [x] **Faithfulness** - Extract claims/truths, generate verdicts, calculate score

### Remaining

- [ ] **Hallucination** - Similar to Faithfulness with inverse logic
  - Reference: `deepeval/metrics/hallucination/hallucination.py`

- [ ] **AnswerRelevancy** - Generate statements from answer, score relevance
  - Reference: `deepeval/metrics/answer_relevancy/answer_relevancy.py`

- [ ] **ContextualPrecision** - RAG retrieval ranking quality
  - Reference: `deepeval/metrics/contextual_precision/`

- [ ] **ContextualRecall** - RAG coverage of ground truth
  - Reference: `deepeval/metrics/contextual_recall/`

---

## Phase 3: Evaluation Engine

**Status: Partially Complete**

- [x] Concurrent evaluator with `Task.async_stream`
- [x] Configurable concurrency
- [x] Telemetry events (`[:deep_eval_ex, :metric, :start | :stop | :exception]`)
- [ ] LLM cost tracking per evaluation
- [ ] Phoenix.LiveDashboard integration
- [ ] ExUnit assertion macros

```elixir
# Planned ExUnit integration
defmodule DeepEvalEx.ExUnit do
  defmacro assert_evaluation(test_case, metrics, opts \\ []) do
    # Custom assertion with detailed failure messages
  end
end
```

---

## Phase 4: Additional LLM Adapters

**Status: Planned**

- [ ] Anthropic adapter (Claude models)
- [ ] Ollama adapter (local models)
- [ ] Retry logic with exponential backoff
- [ ] Rate limiting GenServer

---

## Phase 5: Phoenix/LiveView Integration

**Status: Planned**

- [ ] Real-time evaluation progress (PubSub updates)
- [ ] Results table with pass/fail indicators
- [ ] Score visualizations
- [ ] Expandable reasoning for each metric

```elixir
# Example LiveView usage
defmodule MyAppWeb.EvaluationLive do
  use MyAppWeb, :live_view

  def handle_event("run_evaluation", %{"test_cases" => cases}, socket) do
    DeepEvalEx.Evaluator.evaluate_async(cases, metrics,
      callback: &send(self(), {:result, &1}))
    {:noreply, assign(socket, running: true)}
  end

  def handle_info({:result, result}, socket) do
    {:noreply, update(socket, :evaluations, &[result | &1])}
  end
end
```

---

## Phase 6: Documentation & Polish

**Status: In Progress**

- [x] Wiki documentation structure
- [x] Configuration guide
- [x] Quick start guide
- [x] Metric documentation (ExactMatch, GEval, Faithfulness)
- [ ] ExDoc documentation with examples
- [ ] Hex.pm package preparation
- [ ] Test coverage > 80%
- [ ] Complete typespecs

---

## Architecture

```
lib/
├── deep_eval_ex/
│   ├── application.ex           # Supervision tree
│   ├── llm/
│   │   ├── adapter.ex           # Behaviour for LLM providers
│   │   └── adapters/
│   │       ├── openai.ex        # OpenAI (gpt-4o, gpt-4o-mini)
│   │       ├── anthropic.ex     # Claude models (planned)
│   │       ├── ollama.ex        # Local models (planned)
│   │       └── mock.ex          # Testing
│   ├── metrics/
│   │   ├── base_metric.ex       # Behaviour + shared logic
│   │   ├── exact_match.ex       # Done
│   │   ├── g_eval.ex            # Done
│   │   ├── faithfulness.ex      # Done
│   │   ├── hallucination.ex     # Planned
│   │   ├── answer_relevancy.ex  # Planned
│   │   ├── contextual_precision.ex  # Planned
│   │   └── contextual_recall.ex     # Planned
│   ├── prompts/                 # LLM prompt templates
│   ├── schemas/                 # Ecto embedded schemas
│   ├── evaluator.ex             # Concurrent evaluation engine
│   └── telemetry.ex             # Observability
└── deep_eval_ex_web/            # Phoenix/LiveView (planned)
    ├── components/
    └── live/
```

---

## Success Criteria

1. Evaluate LLM outputs against 7 core metrics
2. Support OpenAI, Anthropic, and Ollama backends
3. Integrate with ExUnit for CI/CD testing
4. Provide Phoenix LiveView components for real-time evaluation
5. Publish to Hex.pm with comprehensive documentation
6. Test coverage > 80%

---

## Contributing

Contributions welcome! Priority areas:

1. **Metrics** - Implement remaining RAG metrics
2. **Adapters** - Add Anthropic and Ollama support
3. **Documentation** - Improve guides and examples
4. **Testing** - Increase test coverage

See the [wiki](./wiki) for implementation patterns.
