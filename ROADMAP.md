# DeepEvalEx Roadmap

DeepEvalEx is an idiomatic Elixir port of
[DeepEval](https://github.com/confident-ai/deepeval). Its goal is behaviour and
output parity with Python **deepeval 4.3.1**: the same scores, reasons and
verdicts for the same judge responses, and the same `test_run_<timestamp>.json`
byte for byte. Parity includes **System One**: deepeval's eval modes that answer
metric questions with a System One model such as TypeSafe's Jev, or any other
provider plugged in behind a generic System One model behaviour.

---

## What parity means

DeepEvalEx reaches parity when every capability rated *core* or *important*
below is done. Two things must match:

- **Behaviour.** For identical inputs and identical judge responses: score,
  success, reason, `verboseLogs`, error text, `strictMode`, `evaluationModel`,
  cost and tokens.
- **Output format.** The exported test run equals deepeval's byte for byte,
  including `testCases`, `conversationalTestCases`, `metricsScores`,
  `traceMetricsScores`, `trace`, `prompts` and the dataset keys. Loading a
  deepeval-written file and saving it again loses nothing.

**System One is part of parity, not an add-on.** That means the three eval
modes (`llm`, `hybrid`, `system_one`, resolved from the metric, then app
config, then `DEEPEVAL_EVAL_MODE`, then `llm`); a generic System One model
behaviour with a TypeSafe (Jev) adapter and a Mock adapter; the whole-chain
runner and the hybrid decision specs (Verdict, Binary, Choice, Score); batching
inside `evaluate`; `JevEval` and `ConversationalJevEval`; classifiers with a
Choice mode; and every ported metric carrying the same System One specs deepeval
gives it.

### How parity is verified

A unit is done only when all of its checks pass in CI:

| Check | What it compares |
|---|---|
| **Golden fixtures** | Real deepeval 4.3.1 runs in the dev container against a scripted judge that returns canned JSON. Fixtures record the rendered prompts, `MetricData` and the test run JSON; the Mock adapter replays the same responses and the export must be byte-equal. |
| **Prompt goldens** | Each metric's 4.3.1 Jinja templates rendered by Python for fixed inputs; the Elixir prompt modules must produce identical strings. |
| **System One goldens** | Generated with deepeval's own System One fakes (including outage, authentication-failure and context-overflow cases). They capture the request, deterministic reason, `verboseLogs`, confidence, fallback reason and batched cost split. No TypeSafe key is needed. |
| **Live checks** | Opt-in, gated on provider keys and excluded by default, following the existing `:live` tag: OpenAI and Anthropic today, plus one `system_one` and one `hybrid` metric against Jev once System One lands. |

The unit tests and the existing byte-parity suite stay green throughout.

### Tiers

| Tier | Meaning |
|---|---|
| **core** | Needed for parity; most users touch it. |
| **important** | Needed for parity; narrower audience. |
| **optional** | Post-parity backlog (P11), picked up on demand. |

---

## Shipped

What has shipped, release by release, is in the [Changelog](CHANGELOG.md):
eight metrics (ExactMatch, GEval, Faithfulness, AnswerRelevancy,
ContextualPrecision, ContextualRecall, Hallucination, ToolCorrectness), the
concurrent evaluator with errored results, OpenAI, Anthropic, Ollama and Mock
adapters with token and cost capture, and a deepeval-compatible test run export
checked byte for byte against golden fixtures from deepeval 4.3.1.

### Known divergences from 4.3.1 today

None known: the parity suites run with no `known_divergence` tag.

---

## Plan

Twelve phases, P0 to P11. P0 to P10 are in parity scope; P11 is the optional
backlog. Each phase lists its goal, exit criteria, dependencies and units.

### P0 Parity verification harness

**Goal:** make byte and behaviour parity mechanically checkable before changing
anything: fixtures from real deepeval in the dev container, System One fixtures
from deepeval's own fakes, and an opt-in live Jev check.
**Exit:** the fixture generators run reproducibly in the dev container with
their output committed; the Elixir helpers replay scripted-judge and System One
fixtures; the live tag exists and is skipped by default.
**Depends on:** none.

| Unit | Title | Tier |
|---|---|---|
| P0.1 | Scripted-judge golden fixture generator | core |
| P0.2 | Prompt template goldens | core |
| P0.3 | System One fixtures from deepeval fakes | core |
| P0.4 | Live Jev check scaffold | core |

### P1 Correct the existing metric surface

**Goal:** make the eight existing metrics match 4.3.1 in `llm` mode:
Hallucination direction, borderline verdicts, `strict_mode`, score-only mode,
flaky, the context/retrieval_context split, exact templates, `verboseLogs`,
GEval logprobs and rubric, and the JSON fallback.
**Exit:** P0.1 and P0.2 fixtures pass for all eight metrics in `llm` mode,
including `verboseLogs`, strict and score-only variants. The changelog lists
the Hallucination flip and the context split as breaking.
**Depends on:** P0.

| Unit | Title | Tier |
|---|---|---|
| P1.1 | Flip Hallucination score direction | core |
| P1.2 | Shared QAG verdict normalisation and scoring | core |
| P1.3 | BaseMetric semantics: strict_mode, score-only, flaky, score_breakdown, skipped | core |
| P1.4 | Separate context and retrieval_context | core |
| P1.5 | LLMTestCase aliases, unknown-key handling and SingleTurnParams | core |
| P1.6 | Verbatim 4.3.1 prompt templates | core |
| P1.7 | verbose_logs on Result and verboseLogs export | core |
| P1.8 | Faithfulness penalize_ambiguous_claims | core |
| P1.9 | trimAndLoadJson fallback for non-structured judges | core |
| P1.10 | GEval logprob-weighted scoring | core |
| P1.11 | GEval Rubric ranges and 4.3.1 behaviour | core |

### P2 Evaluation engine and output parity

**Goal:** make `evaluate` and `assert_test` behave like deepeval: return shape,
ErrorConfig, AsyncConfig, timeout strings, full TestRun keys, the rolling
snapshot and env-var settings.
**Exit:** errored, skipped, timed-out, strict and flaky runs export
byte-identical to deepeval; a rich deepeval test run round-trips without loss;
ExUnit failure messages match `assert_test`.
**Depends on:** P1.

| Unit | Title | Tier |
|---|---|---|
| P2.1 | EvaluationResult/TestResult return shape | core |
| P2.2 | ErrorConfig: ignore_errors and skip_on_missing_params | core |
| P2.3 | AsyncConfig parity | core |
| P2.4 | Timeout error strings | important |
| P2.5 | Full TestRun top-level keys and lossless round-trip | core |
| P2.6 | Rolling latest-run snapshot | important |
| P2.7 | assert_test semantics in ExUnit assertions | core |
| P2.8 | Settings and env-var parity | important |
| P2.9 | Retry policy parity | important |

### P3 System One foundation

**Goal:** build the System One stack once so any metric can opt in: behaviour
and schemas, eval-mode resolution, budget limits, TypeSafe (Jev) and Mock
adapters, BaseMetric fields, decision helpers, QAG verdicts, question
primitives, the whole-chain runner and export semantics.
**Exit:** against the Mock adapter and P0.3 fixtures, eval-mode precedence,
hybrid fallback reasons, the disable-on-authentication-failure rule, whole-chain
reason, `verboseLogs` and score, and budget errors all match. The TypeSafe
adapter passes contract tests against recorded payloads.
**Depends on:** P1, P2.

| Unit | Title | Tier |
|---|---|---|
| P3.1 | System One behaviour and question/answer schemas | core |
| P3.2 | Eval mode resolution | core |
| P3.3 | Context budget pre-check | core |
| P3.4 | Mock System One adapter | core |
| P3.5 | TypeSafe (Jev) adapter | core |
| P3.6 | BaseMetric System One state | core |
| P3.7 | Decision helpers with hybrid fallback | core |
| P3.8 | QAG verdicts via System One | core |
| P3.9 | Noul/Score/Choice question primitives and parse_questions | core |
| P3.10 | Whole-chain runner | core |
| P3.11 | Export semantics in System One modes | core |

### P4 System One wiring, JevEval and batching

**Goal:** give every existing metric the System One support deepeval gives it,
ship `JevEval`, and batch `system_one` metrics per test case in `evaluate`.
**Exit:** all eight metrics match the P0.3 fixtures in `llm`, `hybrid` and
`system_one` modes where applicable; `JevEval` matches deepeval's tests;
batched runs score the same as unbatched runs and match the cost split; the
live Jev check passes with a key.
**Depends on:** P3.

| Unit | Title | Tier |
|---|---|---|
| P4.1 | Faithfulness and AnswerRelevancy System One specs | core |
| P4.2 | ContextualPrecision and ContextualRecall System One specs | core |
| P4.3 | Hallucination System One specs | core |
| P4.4 | ToolCorrectness tool-selection ScoreSpec | core |
| P4.5 | GEval and ExactMatch eval-mode regression tests | core |
| P4.6 | JevEval metric | core |
| P4.7 | Batched System One execution in evaluate | important |
| P4.8 | System One request telemetry | important |
| P4.9 | Live Jev check | core |

### P5 Single-turn metric breadth

**Goal:** port the remaining commonly used single-turn metrics, each with its
deepeval System One spec, plus user-overridable templates.
**Exit:** each new metric passes its `llm`, prompt and System One fixtures; a
template override is exercised in tests.
**Depends on:** P4.

| Unit | Title | Tier |
|---|---|---|
| P5.1 | ContextualRelevancyMetric | core |
| P5.2 | Bias and Toxicity | important |
| P5.3 | PIILeakage and PromptAlignment | important |
| P5.4 | ArgumentCorrectnessMetric | important |
| P5.5 | PatternMatch and ToolPermission | important |
| P5.6 | JsonCorrectnessMetric | important |
| P5.7 | SummarizationMetric | important |
| P5.8 | evaluation_template override | important |

### P6 Datasets and goldens

**Goal:** load and save deepeval datasets unchanged and run tasks over goldens.
**Exit:** deepeval-produced CSV, JSON and JSONL datasets load unchanged; files
saved by DeepEvalEx load in Python deepeval; `Dataset.evaluate` produces a
byte-parity test run.
**Depends on:** P2.

| Unit | Title | Tier |
|---|---|---|
| P6.1 | RetrievedContextData | important |
| P6.2 | Golden struct | core |
| P6.3 | EvaluationDataset core | core |
| P6.4 | Dataset loaders (CSV, JSON, JSONL) | core |
| P6.5 | Dataset save_as | important |
| P6.6 | Dataset.evaluate(task) | important |

### P7 Multi-turn (conversational) stack

**Goal:** `ConversationalTestCase`, its export and the commonly used
conversational metrics, all with System One specs, plus `ConversationalJevEval`.
**Exit:** conversational fixtures (`llm` and System One) pass for every metric
in the phase; `conversationalTestCases` export and load byte-identically; a
mixed list of single-turn and conversational cases is rejected.
**Depends on:** P4, P6.

| Unit | Title | Tier |
|---|---|---|
| P7.1 | ConversationalTestCase, Turn and MultiTurnParams | core |
| P7.2 | Turn formatting and windowing utilities | core |
| P7.3 | BaseConversationalMetric contract | core |
| P7.4 | Conversational test run export | core |
| P7.5 | ConversationalGEval | core |
| P7.6 | TurnRelevancy and ConversationCompleteness | core |
| P7.7 | KnowledgeRetention and RoleAdherence | important |
| P7.8 | Turn* RAG metrics | important |
| P7.9 | ConversationalJevEval | important |
| P7.10 | GoalAccuracy and ToolUse | important |
| P7.11 | ConversationalGolden and Persona core fields | important |

### P8 Test runner, console report, cache, classifiers and expectations

**Goal:** match `deepeval test run` and `assert_test` end to end, add the test
run cache, and add the Choice-based classifiers and expectations that Jev
answers natively.
**Exit:** a `mix deep_eval.test` run writes a single deepeval-compatible test
run; cache hits reproduce `MetricData` at zero cost; classifier and expectation
fixtures match Python in `llm` and `system_one` modes.
**Depends on:** P2, P4.

| Unit | Title | Tier |
|---|---|---|
| P8.1 | Console report | important |
| P8.2 | ExUnit test-run collector | important |
| P8.3 | Test run cache | important |
| P8.4 | Classifier framework and expected_labels | important |
| P8.5 | Expectations and the expectation evaluator | important |

### P9 Tracing and agentic evaluation

**Goal:** a span and trace model in Elixir style, component-level evaluation,
the trace export, and the trace-consuming agentic metrics with System One specs.
**Exit:** an agentic fixture from Python (a traced app with span metrics)
exports `trace` and `traceMetricsScores` byte-identically; the agentic metrics
pass their `llm` and System One fixtures.
**Depends on:** P2, P4, P6.

| Unit | Title | Tier |
|---|---|---|
| P9.1 | Span and Trace data model | core |
| P9.2 | span/observe and trace APIs with context propagation | core |
| P9.3 | Context update API | core |
| P9.4 | TraceApi export and traceMetricsScores | core |
| P9.5 | Nested trace dict and compact_trace | core |
| P9.6 | Component-level evaluation executor | core |
| P9.7 | evaluate_traced over goldens and assert_trace | core |
| P9.8 | TaskCompletion and StepEfficiency | core |
| P9.9 | PlanQuality and PlanAdherence | core |
| P9.10 | AgentLoopDetection | important |
| P9.11 | GEval trace mode | important |
| P9.12 | LLM spans from our adapters | important |

### P10 Remaining important extensions

**Goal:** close the remaining important-tier capabilities: DAG, providers,
multimodal, MCP, arena, synthesizer and simulator.
**Exit:** each unit passes fixtures generated from Python for its prompts and
exports. After this phase every core and important capability is done.
**Depends on:** P5, P7, P9.

| Unit | Title | Tier |
|---|---|---|
| P10.1 | DAGMetric | important |
| P10.2 | Azure OpenAI and gateway adapters plus capability registry | important |
| P10.3 | Gemini adapter | important |
| P10.4 | Multimodal test cases and image input | important |
| P10.5 | MCP types | important |
| P10.6 | ArenaTestCase | important |
| P10.7 | Synthesizer from contexts and scratch with evolutions | important |
| P10.8 | ConversationSimulator | important |

### P11 Optional backlog (post-parity)

**Goal:** niche capabilities, picked up on demand.
**Exit:** each unit is held to the same fixture standard when picked up.
**Depends on:** P10.

| Unit | Title | Tier |
|---|---|---|
| P11.1 | NonAdvice, Misuse and RoleViolation | optional |
| P11.2 | ArenaGEval and compare() | optional |
| P11.3 | ConversationalDAG, TopicAdherence and MCP metrics | optional |
| P11.4 | Image metrics | optional |
| P11.5 | Built-in classifiers | optional |
| P11.6 | Audio, voice and transcription | optional |
| P11.7 | Benchmarks, scorer and optimizer | optional |
| P11.8 | SQLite local store, OpenTelemetry bridge and misc | optional |

---

## Effort profile

Effort is described by what drives the cost of the work, not by calendar time:

- **Units:** commit-sized pieces of work, each going through implement, gate
  and review.
- **Shape:** *Port* (deepeval is the reference and the output is
  fixture-checkable), *Adapt* (an Elixir-idiomatic redesign of a Python
  mechanism) or *Design* (no reference, or an undocumented one).
- **Verification:** *Fixture* (golden files from real deepeval), *Fake*
  (deepeval's System One fakes), *Live* (needs provider credentials) or
  *Judgement* (needs human review).
- **Maintainer input:** decisions or access only a maintainer can supply. These
  are the real blockers.
- **Lanes:** how many units can run in parallel without touching the same files.

| Phase | Units | Shape | Verification | Maintainer input | Lanes |
|---|---|---|---|---|---|
| P0 Harness | 4 | Adapt | Self-checking | None | 1 (blocks everything) |
| P1 Fix existing metrics | 11 | Port | Fixture | Accept breaking changes (Hallucination direction, context split) | 2–3 (by metric) |
| P2 Engine and output | 9 | Port | Fixture | Accept the result-shape change | 2 |
| P3 System One foundation | 11 | Design + port | Fake + live | Approve the System One behaviour API; a TypeSafe API key | 1–2 (sequential core) |
| P4 System One wiring and JevEval | 9 | Port | Fake + live | None | 4+ (per metric) |
| P5 More single-turn metrics | 8 | Port | Fixture + fake | None | 6+ (independent metrics) |
| P6 Datasets | 6 | Port | Fixture | None | 2 (parallel with P5) |
| P7 Multi-turn | 11 | Port + adapt | Fixture + fake | None | 3 |
| P8 Runner, cache, classifiers | 5 | Adapt | Fixture + judgement | Mix task and CLI UX | 2 |
| P9 Tracing and agents | 12 | Design + adapt | Fixture + judgement | Span and observe API shape (telemetry/OpenTelemetry) | 2 |
| P10 Remaining important | 8 | Mixed | Fixture + live | Gemini/Azure access; whether to include synthesizer and simulator | 4 |
| P11 Optional backlog | 8 | Port | Fixture | Which items, if any | Many |

**Totals:** 102 units, 90 of them in parity scope (P0–P10).

**Critical path:** P0 → P1 → P2 → P3 → P4. Once P4 lands, P5, P6, P7 and P9
can run as parallel lanes.

**Where the real cost sits:** the Design-shaped units (the generic System One
API and Jev contract in P3; span capture and context propagation in P9) and the
points that need maintainer input. Port-shaped work, about two-thirds of the
units, is bounded by review throughput rather than authoring.

---

## Beyond parity

Planned after parity, and not part of deepeval:

- **Trials and statistics.** Repeated trials per test case with `pass@k` and
  `pass^k`, confidence intervals on scores and pass rates, and paired
  comparison of two runs over the same test cases.
- **Judge alignment.** Measure a judge against human labels: true positive and
  true negative rates and Cohen's kappa, so a metric's threshold and template
  can be tuned against ground truth.

---

## Out of scope

Never built, with the Elixir alternative where there is one:

| Item | Why | Alternative |
|---|---|---|
| RAGAS wrappers (`RAGAS*` metrics, `RagasMetric`) | Thin wrappers over the Python ragas library and LangChain. | The native AnswerRelevancy, Faithfulness and Contextual* metrics; `RagasMetric` could be an alias that averages them. |
| Confident AI: dataset push/pull/queue/versions, test run upload, view, login, gate, metric collections, cloud runs, `confident_link` | Only work against Confident AI's hosted API. | Byte-compatible local test run and dataset files that deepeval can upload; `confident_link` and `test_run_id` stay `nil` for shape parity. |
| Trace posting worker and offline evals (`evaluate_trace/span/thread`) | Confident AI cloud transport and server-side metric collections. | A pluggable trace sink that writes TraceApi JSON locally or exports through OpenTelemetry, and local evaluation of stored traces. |
| Python framework integrations (LangChain/LangGraph, LlamaIndex, CrewAI, Pydantic AI, Strands, AgentCore, Google ADK, Hugging Face, OpenAI Agents SDK) | Exist only in the Python ecosystem. | A telemetry bridge mapping events from Jido, LangChain-Elixir or Req to span types, the OpenTelemetry bridge (P11.8), and LLM spans from our own adapters (P9.12). |
| pytest plugin internals | Internals of the Python test runner. | `DeepEvalEx.ExUnit` assertions plus the `mix deep_eval.test` collector (P8.2). |
| `deepeval inspect` terminal UI | A Python terminal UI; the real `deepeval inspect` works on our byte-compatible files. | A text summary from a Mix task, or a LiveView or Livebook view. |
| DisplayConfig HTML/Markdown file export | Deprecated upstream in favour of the results folder JSON. | Render Markdown from `DeepEvalEx.TestRun` if needed. |
| Red teaming | deepeval 4.3.1 ships only a README; the code moved to DeepTeam. | Safety metrics (Bias, Toxicity, PIILeakage, Misuse). A DeepTeam port would be a separate project. |
| Prompt push/pull/versioning and annotation | Confident AI cloud features. | Prompts versioned in the repo, and local human labels through judge alignment. |
| Legacy local NLP models (Detoxify, SummaC, unbias, ...) | Tied to Python transformers; current metrics do not use them. | Bumblebee/Nx serving if ever needed. |
| Usage analytics, rich progress bars and the Jev progress indicator | Product analytics and terminal UI, not behaviour. | The existing `:telemetry` events plus System One request events (P4.8). |
| The Typer CLI as such (`set-eval-mode`, `set-typesafe`, settings persistence) and deprecated enum aliases | Python CLI and dotenv details; parity needs the same env vars, covered by P2.8 and P3.5. | The same `DEEPEVAL_*` and `TYPESAFE_*` env vars plus `config :deep_eval_ex`. |

---

## Risks

- **Jev wire contract is only partly documented.** Contract tests are built
  from recorded payloads, the context-overflow error is matched defensively,
  and the live Jev check runs in CI when a key is available.
- **System One fixtures depend on deepeval's test fakes**, which are not public
  API. An upgrade can change reason text, request shape or banding thresholds,
  so fixtures are pinned to 4.3.1 and regenerated deliberately.
- **Deterministic System One reasons must match byte for byte** (verbalised
  bands, the 0.15 margin, float formatting), as must token estimates, where
  Python's `json.dumps(ensure_ascii=False)` and Jason can differ at budget
  boundaries.
- **Breaking changes for current users:** Hallucination direction (P1.1), the
  context/retrieval_context split (P1.4), `ignore_errors` defaulting to false
  (P2.2) and the `evaluate` return shape (P2.1). These ship in a 0.x minor bump
  with changelog migration notes, and compatibility options where they are
  cheap.
- **GEval logprob weighting** makes scores depend on OpenAI logprob payloads.
  Judges without logprobs (Anthropic, Ollama) fall back to the raw score, as in
  deepeval, so fixtures must cover both paths.
- **Tier ratings differ between areas** for tracing, agentic metrics, eval
  modes and ArgumentCorrectness. This plan treats System One as core and
  tracing and agentic metrics as required for parity (P9), sequenced after the
  single-turn and multi-turn work.
- **Scope is large.** Tracing is the heaviest Design-shaped phase, because
  context propagation across processes and Tasks needs care. P5, P6, P7 and P9
  run in parallel once P3 and P4 land.
- **Verbatim templates are a maintenance burden.** The P0.2 goldens catch drift,
  but every deepeval upgrade means regenerating fixtures across all metrics.
- **Multimodal cases in System One.** Whether Jev accepts image parts is
  unknown; deepeval returns no System One spec for multimodal cases, so
  DeepEvalEx does the same and falls back to `llm`.
- **Cache and batching interact.** A cached metric must not be batched, and
  cache keys must include the System One model name. P4.7 can ship before
  P8.3 but is revisited when the cache lands.

---

## Architecture

```
lib/deep_eval_ex.ex              # Public API: evaluate, evaluate_run (evaluate_batch deprecated)
lib/deep_eval_ex/
├── evaluator.ex                 # Concurrent evaluation engine
├── ex_unit.ex                   # ExUnit assertions
├── telemetry.ex                 # Telemetry events
├── test_run.ex                  # deepeval TestRun export/import
├── test_run/                    # JSON encoding, local results folder
├── llm/
│   ├── adapter.ex               # Behaviour for LLM providers
│   ├── strict_schema.ex         # JSON schemas for OpenAI strict outputs
│   ├── usage.ex                 # Token usage capture
│   ├── pricing.ex               # Per-model cost
│   └── adapters/                # openai, anthropic, ollama, mock
├── metrics/                     # BaseMetric + one module per metric
├── prompts/                     # Judge prompt templates
└── schemas/                     # TestCase, ToolCall, Result, metric outputs (Peri)
```

---

## Contributing

Contributions are welcome, especially on the units above. See the README's
*Development* section for the dev container, the gate, live checks and
regenerating parity fixtures, and the [Custom
Metrics](wiki/guides/Custom-Metrics.md) and [Custom LLM
Adapters](wiki/guides/Custom-LLM-Adapters.md) guides for implementation
patterns. Every user-visible change adds an entry under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md) in the same commit.
