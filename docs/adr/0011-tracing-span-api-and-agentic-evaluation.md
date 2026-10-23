# ADR-0011: Tracing, the Span API and Agentic Evaluation

## Status

Proposed

## Date

2026-10-23

## Context

deepeval 4.3.1 evaluates agents through **traces**. Users decorate functions with `@observe(type=...)`. Each call becomes a span:

- `BaseSpan` and its subtypes `AgentSpan`, `LlmSpan`, `RetrieverSpan` and `ToolSpan` (`tracing/types.py`);
- spans are nested under a `Trace` by a global `trace_manager` (`tracing/tracing.py`);
- the current span and trace are held in `ContextVar`s (`tracing/context.py`), which asyncio copies into every task it creates.

Users enrich spans with `update_current_span`, `update_current_trace`, the typed `update_llm_span`, `update_agent_span`, `update_tool_span` and `update_retriever_span`, and the `next_*_span` context managers, which stage values for the next span of a type.

Evaluation runs through `dataset.evals_iterator()`. It hands each golden to user code, collects the resulting trace, then runs:

- trace-level (end-to-end) metrics on an `LLMTestCase` built from the trace and the golden;
- component-level metrics declared on spans, in a depth-first walk (`evaluate/execute/loop.py` for sync, `evaluate/execute/agentic.py` for async).

The trace is exported into `test_run.json` as `testCases[].trace` (`TraceApi`, spans bucketed by type) plus the run-level `traceMetricsScores`. Metrics that set `requires_trace` (TaskCompletion, StepEfficiency, PlanQuality, PlanAdherence, AgentLoopDetection, and GEval and JevEval in trace mode) read the private `test_case._trace_dict` (`create_nested_spans_dict`). System One specs carry the trace as `compact_trace` (`metrics/utils/system_one.py`).

DeepEvalEx has none of this today:

- `TestRun` passes `trace_metrics_scores` and the test-case `trace` through as raw values (`test_run.ex`), so only the `round_trip/traced_dataset` fixture exercises them.
- `LLM.Usage` and `SystemOne.Ledger` are process-scoped and cross Tasks only through `Usage.async/await` (ADR-0009 decision 11). ADR-0009 deferred a shared scope helper "until a third scope appears". The trace context is that third scope.
- `:telemetry` is the observability layer (ADR-0003). Events are `[:deep_eval_ex, :metric | :evaluation | :system_one, ...]`.

Reading the reference turned up several findings that constrain any design:

1. **The two iterator modes differ.**
   - The **sync** iterator (`loop.py` `execute_agentic_test_cases_from_loop`) wraps each golden in `Observer("custom", PYTEST_TRACE_TEST_WRAPPER_SPAN_NAME)`. Its `end_trace` in `EVALUATE`/`ITERATOR_SYNC` mode rewrites `root_spans = [root_spans[0].children[0]]` (`tracing.py:393-400`), which silently drops a second top-level user span. The wrapper's empty kwargs make `trace.input == {}`, so `create_api_trace`'s `input or golden.input` falls back to the golden. `trace.output` stays `None` unless the user sets it.
   - The **async** iterator (`a_execute_agentic_test_cases_from_loop`) opens **no** wrapper and does **no** unwrap. Every trace started while a golden's coroutine runs is mapped to that golden (`EvalSession.trace_uuid_to_golden`) and becomes its own test case. An exception in the coroutine marks the trace and its root ERRORED with `format_error_text(exc)`.
2. **The two walk orders differ.**
   - **Sync:** for each span, append the api span to its bucket (pre-order), skip on error, recurse into the children, then run the span's own metrics (post-order). A test case is built when `span.input is not None` (`loop.py:285`).
   - **Async:** first the trace test case, then for each span: append the api span, skip on error, run its metrics, then `create_task` each child and gather. A test case is built when `span.input` is truthy (`agentic.py:383`). If metrics never really suspend, asyncio runs this in **breadth-first level order**. If they do suspend, the order is nondeterministic.
   - Async also walks **every** root; sync walks one.
3. **The default input is the call's arguments.** `Observer` sets `span.input = mask(function_kwargs)` from `inspect.signature().bind(...).apply_defaults()` whenever the user did not set an input, so a zero-argument function gets `{}`. `TestCase.input` is `str(span.input)`, which is Python's `dict` repr in **insertion order**. Elixir maps of 32 keys or fewer sort their keys.
4. **Children are attached when a span starts.** `add_span_to_trace` appends the child when the span is entered. On exit, `tools_called` is derived from the ToolSpan children, the first root to exit sets the trace's input and output, and an errored root marks the trace ERRORED. A trace ends when no active span remains.
5. **Timestamps are truncated.** `to_zod_compatible_iso` uses `isoformat(timespec="milliseconds")`, which truncates rather than rounds, converts to UTC and ends in `Z`. `tokenTimes` keys use microseconds.
6. **OpenTelemetry has no local parity surface.** `tracing/otel/*` exists to ship spans to Confident AI. It reads `gen_ai.*` attributes and writes `confident.*` ones. The posting worker, `offline_evals` and `patchers.py` serve Confident AI too, which is out of scope (ROADMAP).
7. **The integrations target Python frameworks** (`integrations/{langchain, llama_index, crewai, pydantic_ai, google_adk, strands, agentcore, openinference, hugging_face}`). They show the extension points, but none of the frameworks has an Elixir counterpart.

The maintainer's requirements are the same as for ADR-0009: behaviour and output parity with deepeval 4.3.1, verified by fixtures from real deepeval, and idiomatic Elixir. The design must also answer four questions:

- What shape should the span/observe API take?
- How does context propagate across processes?
- How does this relate to OpenTelemetry?
- How do users instrument Jido, LangChain-Elixir and plain GenServer agents?

## Decision

Add a `DeepEvalEx.Tracing` subsystem in three layers.

1. **Capture**, which is impure and process-scoped:
   - a `%Span{}` struct with a `:type` field;
   - a process-dictionary context, `Tracing.Ctx`;
   - a small ETS-backed `Tracing.Store`, in which each span row is written only by the process that owns the span;
   - the primitives `open_span/2`, `close_span/2` and `record_span/2`, with `span/3` and a def-level `deftraced` macro on top.
2. **Parity core**, made of pure functions over a closed, flat set of spans:
   - `Tree` (tree building and the derived fields);
   - `Api` (TraceApi);
   - `NestedDict`;
   - `CompactTrace`;
   - `TestRun.TraceMetricScores`.

   All of these can be fixture-tested from hand-built span lists without running agent code.
3. **Evaluation**: `Evaluator.Agentic` ports both of deepeval's walkers exactly; `DeepEvalEx.evaluate_traced/3` replaces `evals_iterator` with one Task per golden; and `DeepEvalEx.ExUnit.assert_trace/3` ports `trace_scope.py`.

**OpenTelemetry is not a dependency in P9.** The store is the source of truth, because OTel attributes cannot hold the arbitrary terms that parity needs (ordered kwargs rendered with Python `str()`), and because evaluation must never depend on a sampler or exporter. `:telemetry` events are emitted but never used to capture spans (ADR-0003). An optional OTel GenAI bridge is a later, separate unit (decision 4).

The rules below pin down behaviour.

### 1. Data model

```elixir
defmodule DeepEvalEx.Tracing.Span do
  @type type :: :base | :agent | :llm | :retriever | :tool
  @type status :: :in_progress | :success | :errored

  defstruct [
    # BaseSpan (types.py), declaration order kept for NestedDict/Api key order
    :uuid, :trace_uuid, :parent_uuid, :name, :input, :output, :error, :metadata,
    :integration, :retrieval_context, :context, :expected_output, :tools_called,
    :expected_tools, :llm_test_case, :metric_collection,
    type: :base, status: :in_progress, metrics: [], children: [], drop: false,
    # timing: wall clock for export, monotonic for duration, seq = start order
    start_us: nil, end_us: nil, seq: nil,
    # AgentSpan
    available_tools: [], agent_handoffs: [],
    # LlmSpan
    model: nil, provider: nil, prompt: nil, prompt_alias: nil, prompt_version: nil,
    prompt_label: nil, prompt_commit_hash: nil, input_token_count: nil,
    output_token_count: nil, cost_per_input_token: nil, cost_per_output_token: nil,
    token_intervals: nil,
    # RetrieverSpan
    embedder: nil, top_k: nil, chunk_size: nil,
    # ToolSpan
    description: nil
  ]
end
```

- There is **one struct with a `:type`**. Per-type Peri schemas (ADR-0008) reject a field that belongs to another type, and require `name` on `:agent` and `:tool`, as deepeval does. `Span.type/1` replaces `isinstance`.
- `Tracing.Trace` ports `Trace`: uuid, status, root_spans, start_us, end_us, name, tags, metadata, thread_id, user_id, input, output, metrics, metric_collection, test_case_id, test_run_id, turn_id, the five test-case params and drop.
- **Input from function arguments is a `Jason.OrderedObject` with string keys.** `Prompts.Python.str/1` renders it as a Python dict repr in insertion order. This is the fix for finding 3.
- `metrics` holds metric **specs** (`module | {module, opts} | struct`), not stateful instances. Results live in the executor, not on the span.
- `TestCase` gains an in-memory `:trace_dict` field holding the nested dict (deepeval's `_trace_dict`). It is never exported. See decision 8.

### 2. Capture: context, store and lifecycle

**Context.** The process dictionary holds `%Tracing.Ctx{trace_uuid, span_uuid, route}`. Here `route` says where a closed trace goes: a capture reference, or `:off`. `Ctx.current/0` resolves the context in this order:

1. the local process dictionary;
2. the nearest `$callers` ancestor that has an open span, looked up in the Store's pid-to-ctx index. This gives `Task`, `Task.async_stream` and `Task.Supervisor` children their parent's context with no user code;
3. `nil`.

The `$callers` lookup happens when the child's **first span opens**, not when the Task is spawned. If the parent closes its span in between, the child attaches to the grandparent. For spawn-time snapshot semantics, Python's copy-on-`create_task`, use `Tracing.async/1`. For any other process (GenServer, `spawn`, Jido agent), hand the context over explicitly with `Tracing.context/0` and `Tracing.with_context/2`. See decision 2.

**Store.** `Tracing.Store` is a GenServer under the application supervisor. It owns one public ETS set table and does no work on the hot path. Rows:

- `{{:span, trace_uuid, span_uuid}, %Span{}}`: written only by the span's owner process, so there is a single writer per key;
- `{{:trace_attr, trace_uuid, field}, value}`: one row per `update_current_trace` field, so concurrent writers merge last-write-wins per field;
- `{{:open, trace_uuid}, count}`: updated with `:ets.update_counter`;
- `{{:pid, pid}, ctx}`: the `$callers` index;
- `{{:closed, route_ref, trace_uuid}, %Trace{}}`: closed traces waiting for their capturer. Delivery goes through ETS, not the mailbox, so a GenServer or LiveView owner never receives tracing messages.

The Store monitors the owner of each trace. If the owner dies with spans still open, it marks those spans ERRORED with the exit reason and closes the trace. Python would leak the trace instead. This deviation is documented.

**Lifecycle** (`open_span/2` and `close_span/2` port `Observer.__enter__` and `__exit__`):

- The parent is the current span. Without one, the current live trace is used; without that, a new trace is started (`drop_if_root: true` skips the span instead).
- The pending `next_*` slot is applied, the typed slot merged over the base slot (`pop_pending_for`, `apply_pending_to_span`).
- `integration` is inherited from the parent.
- `seq` is set from `System.unique_integer([:monotonic, :positive])`.
- On a raise, throw or exit, the span becomes ERRORED with `error` set to `Exception.message/1` (Python `str(exc)`), or `inspect/1` for a throw or exit. The original kind and stacktrace are re-raised. An `{:error, _}` return is **not** an error (decision 13).
- When the user set no input, `input` defaults to the masked kwargs from `deftraced`. For `span/3`, it is `:input`, else nil. When the user set no output, `output` defaults to the masked result.
- LlmSpans get their `prompt` fields filled.
- When the trace's open-span count drops to 0, the closing process builds the trace with `Tree.build/2` and routes it: to a capture reference, or under `:off` to the configured sink plus `[:deep_eval_ex, :trace, :stop]`.

**Derived fields are computed when the trace closes, in `Tree.build/2`** (pure). For spans that live in one process the result is identical to deepeval's exit-time mutation:

- children are sorted by `seq`;
- a span whose parent is missing becomes a root, as in `_reparent_orphan_roots`;
- `tools_called` comes from ToolSpan children (`prepare_tool_call_input_parameters` wraps a non-map in `%{"output" => x}`);
- the trace's input and output come from the first root to close, when unset;
- an errored root marks the trace ERRORED;
- under `mode: :sync` evaluation, the wrapper strip is applied.

The divergence that remains, a ToolSpan that ends after its parent, is documented.

**Judge suppression.** `BaseMetric.measure/2` runs inside `Tracing.suppress/1`. An LLM call made by a metric's judge therefore never appears in a user trace, as with deepeval's `_internal` observe. Its usage still reaches `Usage` and telemetry.

### 3. Public API

```elixir
defmodule DeepEvalEx.Tracing do
  @type span_type :: :base | :agent | :llm | :retriever | :tool
  @type metric_spec :: module() | {module(), keyword()} | struct()

  # Spans
  @spec span(span_type(), keyword(), (-> r)) :: r when r: term()
  #   opts: name, input, metrics: [metric_spec], metric_collection, metadata, drop_if_root,
  #         + type keys: available_tools, agent_handoffs | model, provider, prompt,
  #           cost_per_input_token, cost_per_output_token | embedder | description
  @spec open_span(span_type(), keyword()) :: {:ok, Ctx.t()} | :ignored   # adapter primitive
  @spec close_span(Ctx.t(), keyword()) :: :ok                            # status:, output:, error:
  @spec record_span(span_type(), keyword()) :: :ok                       # already finished (start_us/end_us given)
  @spec trace(keyword(), (-> r)) :: r when r: term()   # trace_context.trace(): reuse the live trace or open one;
                                                       # llm_span_context:/agent_span_context: seed pending slots
  @spec suppress((-> r)) :: r when r: term()

  # context.py (Python truthiness: nil/false/""/[]/%{}/0 do not overwrite;
  # integration and provider use `is not None`)
  @spec update_current_span(keyword()) :: :ok    # input, output, retrieval_context, context, expected_output,
                                                 # tools_called, expected_tools, metadata, name, test_case,
                                                 # metrics, metric_collection, integration
  @spec update_current_trace(keyword()) :: :ok   # name, tags, metadata, thread_id, user_id, input, output,
                                                 # retrieval_context, context, expected_output, tools_called,
                                                 # expected_tools, test_case, metrics, metric_collection
  @spec update_llm_span(keyword()) :: :ok        # no-op unless the current span is :llm
  @spec update_agent_span(keyword()) :: :ok
  @spec update_tool_span(keyword()) :: :ok
  @spec update_retriever_span(keyword()) :: :ok
  @spec next_span(keyword(), (-> r)) :: r when r: term()   # also next_agent_span/2, next_llm_span/2,
                                                           # next_tool_span/2, next_retriever_span/2
  @spec drop_current_span() :: :ok
  @spec drop_current_trace() :: :ok

  # Crossing processes
  @spec context() :: Ctx.t() | nil
  @spec with_context(Ctx.t() | nil, (-> r)) :: r when r: term()   # restores the previous ctx in `after`
  @spec async((-> term())) :: Task.t()          # snapshot at spawn; carries Usage + Ledger + ctx (DeepEvalEx.Scope)
  @spec await(Task.t(), timeout()) :: term()

  # Capture
  @spec capture(keyword(), (-> r)) :: {r, [Trace.t()]} when r: term()
  #   every trace started under fun (and its $callers/async descendants), in start order;
  #   await_open: 5_000 bounds the wait for spans still open in live processes
end
```

The decorator equivalent is a **def-level macro**, not an `@observe` attribute:

```elixir
defmodule MyApp.Support do
  use DeepEvalEx.Tracing                      # imports deftraced/3, defptraced/3
  alias DeepEvalEx.Tracing

  deftraced answer(query), type: :agent, available_tools: ["retrieve"] do
    docs = retrieve(query)
    generate(query, docs)
  end

  deftraced retrieve(query, k \\ 2), type: :retriever, embedder: "text-embedding-3-small" do
    docs = MyApp.Search.top_k(query, k)
    Tracing.update_current_span(retrieval_context: docs)
    docs
  end

  deftraced generate(query, documents), type: :llm, model: "gpt-4o-mini",
    metrics: [{DeepEvalEx.Metrics.AnswerRelevancy, threshold: 0.7}] do
    {:ok, text, usage} = MyApp.LLM.chat(query, documents)
    Tracing.update_llm_span(input_token_count: usage.input, output_token_count: usage.output)
    text
  end
end
# retrieve("q") -> span name "retrieve", input OrderedObject [{"query","q"},{"k",2}]
```

`deftraced` works as follows:

- It wraps the body in `span/3`, so stacktraces show one extra frame.
- It names the span after the function.
- It builds the ordered kwargs from the clause head. Plain variables keep their name, `x = pattern` uses `x`, `_name` uses `name`, and any other pattern is bound to a generated variable named `arg<i>`. Defaults are bound after `\\` expansion, mirroring `apply_defaults`.
- It composes with `@doc`, `@spec` and guards.
- A multi-clause function puts every clause under one `deftraced` head, so a call yields one span, not one per clause.

Crossing processes:

```elixir
# Task: inherited through $callers, no code needed
Task.async_stream(tools, &MyApp.Support.call_tool/1) |> Enum.to_list()

# Deterministic snapshot (also forwards Usage and the System One Ledger)
tasks = Enum.map(urls, fn u -> DeepEvalEx.Tracing.async(fn -> fetch(u) end) end)
Enum.map(tasks, &DeepEvalEx.Tracing.await/1)

# GenServer, Jido agent, spawn: explicit hand-off
GenServer.call(planner, {:plan, goal, DeepEvalEx.Tracing.context()})
def handle_call({:plan, goal, ctx}, _from, s),
  do: {:reply, DeepEvalEx.Tracing.with_context(ctx, fn -> plan(goal) end), s}
```

Evaluation and tests:

```elixir
@spec DeepEvalEx.evaluate_traced([Golden.t()] | EvaluationDataset.t(), (Golden.t() -> term()), keyword()) ::
        DeepEvalEx.EvaluationResult.t()
# opts: metrics: (trace-level), mode: :async | :sync (default :async = deepeval run_async=True),
#       plus evaluate_run/3's ignore_errors, skip_on_missing_params, identifier, hyperparameters,
#       max_concurrency, timeout

{:ok, dataset} = DeepEvalEx.Dataset.EvaluationDataset.from_json("goldens.json")
DeepEvalEx.evaluate_traced(dataset, fn g -> MyApp.Support.answer(g.input) end,
  metrics: [DeepEvalEx.Metrics.TaskCompletion, DeepEvalEx.Metrics.StepEfficiency],
  identifier: "support-agent-v3")
# writes .deepeval/test_run_<ts>.json with testCases[].trace and traceMetricsScores

use DeepEvalEx.ExUnit
test "refund agent completes the task", %{golden: g} do
  assert_trace g, [DeepEvalEx.Metrics.TaskCompletion], fn -> MyApp.Refunds.run(g.input) end
end

# Raw traces outside evaluation
{_answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)
DeepEvalEx.Tracing.Api.trace_api(trace) |> Jason.encode!(pretty: true)
```

`BaseMetric` gains an optional callback with two arities, like `metric_name/0,1`. It defaults to `false`. The trace metrics return `true`, and GEval and JevEval compute it from their struct:

```elixir
@callback requires_trace?() :: boolean()
@callback requires_trace?(metric :: struct()) :: boolean()
```

Telemetry (ADR-0003) is emitted, never consumed, and its metadata is deepeval-shaped:

```elixir
[:deep_eval_ex, :span, :start | :stop | :exception]  # meta: %{span: %Span{}, trace_uuid, parent_uuid, type}
[:deep_eval_ex, :trace, :stop]                       # meta: %{trace: %Trace{}, route: :off | :capture}
```

Generic third-party capture, from any library that emits `:telemetry.span` events:

```elixir
DeepEvalEx.Tracing.TelemetryBridge.attach(:my_agent, [:my_app, :agent, :step], fn
  :start, _m, %{tool: t} = meta -> {:tool, name: t, input: meta.args}
  :start, _m, meta -> {:agent, name: meta.agent}
  :stop, _m, meta -> {:update, output: meta.result}
  _, _, _ -> :skip
end)
```

The bridge handlers run in the emitting process, so the pdict context applies unchanged. Start and stop are paired by `telemetry_span_context`.

### 4. Evaluation

`evaluate_traced/3` starts one Task per golden under `Task.async_stream` (ADR-0004). Each Task sets `route` to its own capture reference, so `EvalSession.trace_uuid_to_golden` is not needed. Then:

- **`mode: :async`**, the default, ports the `ITERATOR_ASYNC` path:
  - there is no wrapper span and no unwrap;
  - **every** trace captured for the golden becomes its own test case, in start order;
  - the trace's input and output come from its root span;
  - a raise in the user function marks the trace and its root ERRORED with `format_error_text`. The cancel and timeout texts are ported as they are.
- **`mode: :sync`** ports `loop.py`:
  - the wrapper span `PYTEST_TRACE_TEST_WRAPPER_SPAN_NAME` has `input: %{}`;
  - `Tree.build/2` applies the `root_spans[0].children[0]` strip, sets `parent_uuid: nil` and drops a second top-level user span, as deepeval does;
  - `trace.input` is `{}`, so the test case falls back to `golden.input`;
  - the trace output stays nil unless set.

`Evaluator.Agentic` ports `agentic.py`, `loop.py`'s `dfs` and `_common.py`:

- The test case at trace level: `actual_output = Prompts.Python.str(trace.output)` when the output is not nil, plus the dataset alias, id and version from the golden. `create_api_trace` starts with empty buckets and uses `input || golden.input`.
- `_skip_metrics_for_error` and `_trace_error`, with deepeval's texts: "Span has metrics but no LLMTestCase. Are you sure you called `update_current_span()`?" and "Trace has metrics but no LLMTestCase (missing input/output)...", both through `format_error_text`.
- `requires_trace?` triggers the `LLMTestCase(input="None")` placeholder and attaches `NestedDict`.
- `filter_duplicate_results`, `extract_trace_test_results` and `update_status`.
- **Walk order:**
  - `:sync` appends api spans pre-order and runs metrics post-order; a test case is built when `span.input != nil`; one root is walked.
  - `:async` runs the trace metrics first, then appends api spans in **BFS level order** computed from the tree, and builds a test case when the input is truthy in Python's sense. Every root is walked. Metric calls run concurrently, but buckets are assembled in the computed order rather than completion order (decision 7).

`TestRun.TraceMetricScores` computes `traceMetricsScores`:

- spans are processed in agent, tool, retriever, llm, base order, keyed by span name and then metric name;
- all five keys appear, in pydantic order;
- the value is `nil` when no span has metricsData;
- span metric rows are folded into `metricsScores`.

A stored run that is loaded keeps its raw value.

### 5. Export (pure)

- **`Tracing.Api.trace_api/2`** ports `create_trace_api` and `_convert_span_to_api_span`:
  - `Jason.OrderedObject` in BaseApiSpan/TraceApi field order, by alias, excluding nil values;
  - buckets in LIFO `span_stack.pop()` order;
  - a dropped span re-parents its children;
  - prompt field precedence;
  - `normalize_trace_api_span_providers` and `infer_provider_from_model`;
  - `metricsData` through the existing `create_metric_data` port, with expectations rows dropped.
- **`Tracing.Time.to_zod_iso/2`** truncates to milliseconds, or to microseconds for `tokenTimes` keys, in UTC with a `Z` suffix. Spans store `System.os_time(:microsecond)`. A clock and uuid generator can be injected (`config :deep_eval_ex, :tracing, clock: ..., uuid: ...`) for unit tests.
- **`Tracing.NestedDict`** ports `create_nested_spans_dict`: the popped keys are uuid, trace_uuid, parent_uuid, start_time, end_time, status, llm_test_case, metrics_data, metric_collection and metadata; None values are dropped; children are recursed. Keys follow pydantic declaration order. `to_json/1` renders it like `serialize_to_json(indent=2)` through `Prompts.Python`.
- **`Tracing.CompactTrace`** ports `compact_trace`: the `_TRACE_SPAN_KEYS` whitelist in order, with nil, `[]` and `""` dropped. It is used in the System One `extra_state` of the trace metrics (ADR-0009 section 4) and in JevEval's trace state.
- **`Tracing.JSON`** ports `make_json_serializable` and `mask`:
  - structs go through the `Dumpable` protocol, else `Map.from_struct`;
  - tuples become lists;
  - atoms become strings;
  - pids, refs and funs go through `inspect`;
  - the mask is optional: `config :deep_eval_ex, :tracing, mask: {M, :f}`.

### Module map

| Module | Ports | Unit |
|---|---|---|
| `Tracing.Span`, `Tracing.Trace` (+ Peri schemas) | `tracing/types.py` | P9-1 |
| `Tracing.Time`, `Tracing.JSON` | `to_zod_compatible_iso`, `make_json_serializable`, `mask` | P9-1 |
| `Tracing.Store`, `Tracing.Ctx`, `Tracing.Tree` | `TraceManager` (start/end trace, add_span_to_trace, reparent), ContextVars | P9-2 |
| `Tracing` facade: `span/3`, `open/close/record_span`, `trace/2`, `capture/2`, `suppress/1`, `context/0`, `with_context/2`, `async/1`, `await/2`; `Tracing.Observe` (`deftraced`) | `tracing.py` `observe`/`Observer`, `trace_context.py` | P9-2 |
| `DeepEvalEx.Scope` (internal carrier fork/join: Usage, Ledger, Tracing ctx) | none (ADR-0009 decision 11 follow-up) | P9-2 |
| `Tracing.Pending`; `update_*` functions | `tracing/context.py` | P9-3 |
| `Tracing.Api`; `TestRun.TraceMetricScores` | `tracing/api.py`, `evaluate/utils.create_api_trace`, `test_run.py` | P9-4 |
| `Tracing.NestedDict`, `Tracing.CompactTrace`; `TestCase.trace_dict` | `create_nested_spans_dict`, `system_one.compact_trace` | P9-5 |
| `Evaluator.Agentic`; `BaseMetric.requires_trace?/0,1` | `evaluate/execute/agentic.py`, `loop.py` dfs, `_common.py` | P9-6 |
| `DeepEvalEx.evaluate_traced/3` (`Evaluator.Traced`), `ExUnit.assert_trace/3`, JevEval trace state | `loop.py` iterators, `dataset.evals_iterator`, `trace_scope.py` | P9-7 |
| `Metrics.TaskCompletion`, `Metrics.StepEfficiency` | `task_completion/`, `step_efficiency/` | P9-8 |
| `Metrics.PlanQuality`, `Metrics.PlanAdherence` | `plan_quality/`, `plan_adherence/` | P9-9 |
| `Metrics.AgentLoopDetection`, `Metrics.Utils.SequenceMatcher` | `agent_loop_detection/`, `difflib.SequenceMatcher.ratio` | P9-10 |
| `Metrics.GEval` trace mode | `g_eval.py` trace templates | P9-11 |
| `LLM.Adapter` facade spans; `Tracing.ReqStep` (optional) | `deepeval.openai`, `deepeval.anthropic` | P9-12 |
| `Tracing.TelemetryBridge`, `Tracing.Sink` (+ `Sinks.Null`, `Sinks.Test`) | `integrations/*` extension point | P9-13 (new) |

## Parity mapping to deepeval 4.3.1

| deepeval | DeepEvalEx | Notes |
|---|---|---|
| `BaseSpan`, `AgentSpan`, `LlmSpan`, `RetrieverSpan`, `ToolSpan` | `Tracing.Span` with `:type` | Field-for-field; enums become atoms serialised with Python values (`SUCCESS`, `agent`, ...) |
| `Trace`, `TraceSpanStatus` | `Tracing.Trace`, `:in_progress \| :success \| :errored` | |
| `observe(type, metrics, metric_collection, _drop_if_root, **kwargs)` | `deftraced ... , type:, metrics:, metric_collection:, drop_if_root:, ...`; `span/3` | kwargs become an ordered map built from the clause head; `_internal` becomes `suppress/1` |
| `Observer.__enter__` / `__exit__` | `open_span/2` / `close_span/2` | Derived fields computed in `Tree.build/2` when the trace closes |
| `current_span_context`, `current_trace_context` (ContextVar) | `Tracing.Ctx` in the process dictionary, plus `$callers` and `async/1` | Python copies at `create_task`; we resolve at first span or snapshot with `async/1` |
| `trace_manager` (`active_traces`, `active_spans`, `traces`) | `Tracing.Store` (ETS) | Owner monitoring is new; there is no global `traces` list (decision 10) |
| `update_current_span`, `update_current_trace`, `update_*_span` | Same names | Same truthiness branches |
| `next_span`, `next_*_span`, `_PendingSlot`, `pop_pending_for`, `apply_pending_to_span` | `next_*_span/2` (fun-scoped), `Tracing.Pending` | Context managers become functions taking a fun |
| `trace_context.trace()`, `LlmSpanContext`, `AgentSpanContext` | `Tracing.trace/2` with `:llm_span_context` and `:agent_span_context` | |
| `create_trace_api`, `_convert_span_to_api_span`, `normalize_trace_api_span_providers` | `Tracing.Api.trace_api/2` | LIFO bucket order |
| `evaluate/utils.create_api_trace` | `Tracing.Api.eval_trace_api/2` | Empty buckets; `input or golden.input` |
| `create_nested_spans_dict`, `serialize_to_json(indent=2)` | `Tracing.NestedDict.build/1`, `to_json/1` | |
| `system_one.compact_trace` | `Tracing.CompactTrace.compact/1` | |
| `loop.execute_agentic_test_cases_from_loop` (sync) | `evaluate_traced(mode: :sync)` | Wrapper span, `children[0]` strip, `is not None`, post-order metrics |
| `loop.a_execute_agentic_test_cases_from_loop` (async) | `evaluate_traced(mode: :async)` | No wrapper, one test case per trace, truthy input, BFS order |
| `agentic.py` `_a_execute_*`; `_common._skip_metrics_for_error`, `_trace_error`, `filter_duplicate_results` | `Evaluator.Agentic` | Error texts verbatim |
| `EvalSession`, `EvalMode`, `trace_uuid_to_golden` | Capture `route` per golden Task | No global session |
| `test_run.TraceMetricScores`, `calculate_metrics_scores` (span half) | `TestRun.TraceMetricScores` | Computed, no longer passed through |
| `metric.requires_trace`, `test_case._trace_dict` | `requires_trace?/0,1`, `TestCase.trace_dict` | |
| `trace_scope._assert_test_from_current_trace`, `trace_test_manager` | `ExUnit.assert_trace/3` | "No active trace found..." text |
| `deepeval.openai`, `deepeval.anthropic` patchers | `LLM.Adapter` facade spans (`drop_if_root: true`), `Tracing.ReqStep` | |
| `integrations/*` | `TelemetryBridge` plus later adapter packages | Python frameworks are not ported |
| `tracing/otel/*`, `offline_evals/*`, posting worker, `patchers.py` | Not ported | Confident AI only; the `Sink` behaviour is the seam |

## Dependencies

There are **no new runtime dependencies**. Tracing uses `:telemetry`, ETS, `Jason.OrderedObject` and Peri, which are all already present. The Store is one GenServer under the existing application supervisor.

- `opentelemetry_api` is **not** added in P9 (decision 4). A later OTel GenAI bridge would declare it with `optional: true` behind `Code.ensure_loaded?/1`, in its own module or package, and would need a `mix compile --no-optional-deps` CI job.
- `jido` and `langchain` are not added. The generic `TelemetryBridge` consumes events without a compile-time dependency. Framework-specific mappers are a later decision (9).
- Test only: `stream_data` for the property tests, if the P3 StreamData property (ADR-0009 testing section 3) has not already brought it in. It is not in `mix.exs` today.

## Testing strategy

1. **Fixtures from real deepeval.** A new `test/fixtures/deepeval/traced/<scenario>/` set is generated in the devcontainer by `scripts/parity/generate_fixtures.py traced`, with no patching of deepeval. Each scenario records:
   - `input.json`: a declarative agent script that both sides interpret into the same call tree (an `@observe`-decorated interpreter in Python, a `deftraced` one in `test/support/tracing_scenarios.ex`), plus metric specs: stub metrics, ExactMatch/PatternMatch, AgentLoopDetection, and ScriptedJudge-backed TaskCompletion, StepEfficiency, PlanQuality and PlanAdherence;
   - `trace_api.json`, `nested.json`, `compact.json` and `test_run.json`.

   Scenarios:
   - nested agent, retriever, llm and tool spans;
   - zero-argument and multi-argument decorated functions (kwargs order and `{}`);
   - a raised span, both caught and uncaught;
   - `update_current_span(test_case=...)`;
   - `next_llm_span` staging;
   - `toolsCalled` auto-filled;
   - a dropped span;
   - two top-level user spans, run in **both** modes (the `children[0]` strip in sync, two test cases in async);
   - a span with metrics but no input (`None` vs `{}`, sync vs async);
   - `requires_trace` metrics;
   - an errored trace skipping its metrics;
   - LlmSpan prompt fields and `token_intervals`;
   - provider normalisation.

   Every agentic scenario runs once with `run_async=False` and once with `run_async=True`. Async scenarios use only metrics that never suspend, so Python's BFS order is deterministic.
2. **Normalisation.** The README's "What the parity test normalises" section gains two rules, each justified because the value differs between two identical runs:
   - span and trace uuids become `<uuid-N>` by first appearance, so `parentUuid` links are still compared;
   - ISO timestamps are first checked against `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$` and `start <= end`, then replaced.

   Exact time formatting is covered separately by `traced/iso_table.json`, a Python-generated table of epoch inputs mapped to `to_zod_compatible_iso` outputs, including truncation edges such as `x.9995` and microsecond keys.
3. **Pure-core tests.**
   - `Tree`, `Api`, `NestedDict`, `CompactTrace` and `TraceMetricScores` are tested from hand-built flat span lists: seq order, orphan adoption, `tools_called`, trace I/O defaults, ERRORED propagation, the sync strip and drop re-parenting.
   - StreamData properties: every span lands in exactly one bucket; the bucket order equals a reference LIFO model; `children` are in start order.
   - `round_trip/traced_dataset` gains a recompute check: `TraceMetricScores` computed from its test cases must equal the stored value.
4. **Capture tests.** All are `async: true` and isolated by trace uuid.
   - The truthiness table for `update_*`, mirroring the branches of `context.py`.
   - `next_*` precedence and consumption.
   - raise, throw and exit each produce ERRORED and are re-raised with the original stacktrace.
   - `deftraced` binding: plain, pattern, `_ignored`, defaults, guards, multi-clause and `defptraced`.
   - Propagation:
     - Task, `Task.async_stream` and `Task.Supervisor.async_nolink` inherit through `$callers`;
     - `Tracing.async` snapshots at spawn;
     - `with_context` restores the previous context on raise;
     - a bare `spawn` starts its own trace;
     - concurrent `update_current_trace` from N tasks loses no field;
     - an owner's DOWN marks its open spans ERRORED;
     - `capture/2` `await_open` expiry exports `IN_PROGRESS`;
     - the owner's mailbox stays empty (`Process.info(:messages)`).
   - Suppression: an adapter call inside `measure/2` creates no span.
   - Telemetry events, checked with `:telemetry_test.attach_event_handlers`.
5. **Metric fixtures.**
   - TaskCompletion, StepEfficiency, PlanQuality, PlanAdherence and GEval trace mode join `scripted/` (prompts, measure, test_run) and `system_one/` (`decide.json` with `compact_trace` in `extra_state`), and `prompt_golden_test` covers every trace template.
   - AgentLoopDetection gets a `difflib.SequenceMatcher.ratio` vector table generated in Python: random strings, junk-heavy inputs and autojunk at 200 or more elements, plus input-hash truncation.
6. **Fakes.**
   - `LLM.Adapters.Mock` drives the P9-12 adapter-span tests: no span outside a trace (`drop_if_root`), and an `:llm` child carrying model and tokens inside one.
   - `Sinks.Test` sends closed traces to a test pid.
   - `TelemetryBridge` is driven by synthetic `:telemetry.span` events.

## Mapping of P9 units

Effort uses the unit briefs' S/M/L scale.

| Unit | Scope under this design | Change from the brief |
|---|---|---|
| **P9-0 (new)** | This ADR; `generate_fixtures.py traced` scenarios and `iso_table.json`; README normalisation amendment | Split out because every later unit's parity check depends on it |
| P9-1 | `Span` (one struct with `:type`, per-type Peri schemas), `Trace`, `Time`, `JSON` | One struct instead of five |
| P9-2 | `Ctx`, `Store`, `Tree`, `span/3`, `open/close/record_span`, `trace/2`, `capture/2`, `suppress/1`, `async/await`, `deftraced`, `DeepEvalEx.Scope`, telemetry events | Capture writes to the Store; `:telemetry.span` only notifies. The observe macro is the def-level `deftraced`. Context is inherited through `$callers` as well as handed off explicitly |
| P9-3 | `update_*`, `next_*`, `Pending`, `drop_current_*` | `next_*` take a fun |
| P9-4 | `Api.trace_api/2`, `eval_trace_api/2`, `TestRun.TraceMetricScores` | `traceMetricsScores` computed; raw value kept on load |
| P9-5 | `NestedDict`, `CompactTrace`, `TestCase.trace_dict` | Field named `:trace_dict` (decision 8) |
| P9-6 | `Evaluator.Agentic`, both walkers, `requires_trace?/0,1` | Two walk orders and input checks, not one DFS |
| P9-7 | `evaluate_traced/3` in both modes, `assert_trace/3`, JevEval trace state | One Task per golden replaces EvalSession routing |
| P9-8 | TaskCompletion, StepEfficiency | None |
| P9-9 | PlanQuality, PlanAdherence | None |
| P9-10 | AgentLoopDetection, `SequenceMatcher` | None |
| P9-11 | GEval trace mode | None |
| P9-12 | Adapter facade spans with `drop_if_root`; optional `Tracing.ReqStep` | Wrapping happens once in the facade; judge calls suppressed |
| **P9-13 (new)** | `TelemetryBridge`, `Sink` behaviour (`Null`, `Test`) | Generic integration seam; framework mappers deferred (decision 9) |

The order is:

1. P9-0 and P9-1 first, in parallel.
2. Then P9-2.
3. Then P9-3, P9-4 and P9-5, in parallel.
4. Then P9-6 and P9-7.
5. P9-8 to P9-11 need only P9-5 and the metric harness, so they can start after P9-5. P9-12 and P9-13 need only P9-2.

## Alternatives Considered

### Faithful port: `@observe` attribute, five structs, global manager and session

This design used five structs sharing fields through a `__using__` macro, an `@on_definition`/`defoverridable` `@observe` attribute, and a global ETS `Manager` plus `Session` with `EvalMode` routing.

- **Kept from it:**
  - the exhaustive parity mapping;
  - owner monitoring that marks spans ERRORED;
  - the ISO truncation table;
  - the explicit BFS order for async;
  - computing `TraceMetricScores` instead of passing it through;
  - the two-arity `requires_trace?`.
- **Rejected:**
  - the attribute rewrite is fragile with multi-clause functions, guards, `defp` and defaults;
  - five structs add a field macro for little gain;
  - a global Session duplicates what one Task per golden gives for free;
  - it opened the wrapper span in async mode too, which is wrong for `ITERATOR_ASYNC`.

### BEAM/OTel-native: telemetry with GenAI semconv metadata, optional `opentelemetry_api`

This was the base of this ADR.

- **Kept from it:**
  - the store as the source of truth;
  - single-writer ETS rows and per-field trace attributes;
  - `deftraced`;
  - `$callers` resolution;
  - judge suppression;
  - one Task per golden;
  - the port of both walk orders and both input checks.
- **Changed:**
  - the wrapper and unwrap now apply only in `:sync`;
  - async order is stated as BFS, not pre-order;
  - fixtures normalise instead of patching deepeval;
  - telemetry metadata is deepeval-shaped, because GenAI semconv is Development status and has already renamed keys (`gen_ai.system` became `gen_ai.provider.name`);
  - the OTel bridge and the Jido, LangChain and Finch mappers move out of P9.

### Minimal explicit API: functions only, explicit hand-off only, per-trace Agent collector

- **Kept from it:**
  - the pure parity core built from flat spans;
  - the `open_span`/`close_span`/`record_span` primitive;
  - the `Sink` seam;
  - the correct per-mode iterator semantics;
  - the warning about map key order.
- **Rejected:**
  - with no macro there is no default kwargs input, so sync-mode span metrics hit "no LLMTestCase" where Python measures `"{}"`, and users must hand-build ordered input to reach parity;
  - explicit-only propagation silently loses spans from a bare `Task.async`, the trap ADR-0009 already lists for the Ledger;
  - the per-trace Agent collector adds a process per trace for what single-writer ETS rows already do.

### OTel spans as the canonical store

- **Rejected.** Attributes are primitives, so terms would have to be JSON-encoded, which loses ordered maps and Python `str()` fidelity. It would also put an SDK, samplers and batch processors on the evaluation path.

## Consequences

### Positive

- **Parity is pinned down.** Both iterator modes, both walk orders, both input checks, the `children[0]` strip, kwargs order and truncated timestamps each have a stated rule and a fixture scenario.
- **The parity core is pure.** `Tree`, `Api`, `NestedDict`, `CompactTrace` and `TraceMetricScores` are tested without processes or agents.
- **Instrumenting Task-based code takes no extra work**, and there is a deterministic snapshot route (`Tracing.async`) that also carries Usage and the Ledger.
- **One fork/join mechanism.** `DeepEvalEx.Scope` closes ADR-0009 decision 11's follow-up, so Usage, the Ledger and the trace context cross Tasks together.
- **No new runtime dependency**, and capture never depends on telemetry handlers or OTel configuration.
- **Judge traffic stays out of user traces.**

### Negative

- **Shared ETS state.** The Store table is global. Correctness relies on a single writer per span row and on owner monitoring, and tests are isolated by uuid rather than by resetting state.
- **The `$callers` race.** A child's first span resolves the parent at open time, not spawn time, which is documented. GenServers and Jido agents still need an explicit context hand-off.
- **Python quirks preserved.** Truthiness in `update_*` (`output: 0` is ignored), the dropped second top-level span in `:sync`, the `"None"` placeholder test case and `{:error, _}` not counting as an error all surprise Elixir users. Each is documented in its moduledoc.
- **Two walker paths and two fixture variants** must be maintained.
- **The fixture rule widens.** Normalising uuids and timestamps goes beyond "only runDuration".
- **Fixtures are limited for async.** Async bucket order is fixture-checked only for non-suspending metrics. Where asyncio is nondeterministic, DeepEvalEx picks BFS order.
- **`deftraced` is not drop-in.** Users rename `def`, and stacktraces gain one frame.
- **Late children diverge.** A ToolSpan that ends after its parent is included in `tools_called`. deepeval would miss it or record its output as None.

### Neutral

- `TestCase` gains `:trace_dict`, `BaseMetric` gains `requires_trace?/0,1`, and `TestRun` stops passing `traceMetricsScores` through.
- New telemetry events under `[:deep_eval_ex, :span | :trace, ...]`.
- Confident AI posting, OTLP export, offline evals and Python-framework integrations stay out of scope. `Sink` and `TelemetryBridge` are the seams for them.

## Decisions Needed From the Maintainer

1. **Instrumentation API shape.**
   - (a) A def-level `deftraced`/`defptraced` macro over `span/3`, with the `open/close/record_span` primitive.
   - (b) An `@observe` attribute decorator (`@on_definition` plus `defoverridable`).
   - (c) Functions only, with no macro.

   **Recommended: (a).** It gives deepeval's kwargs-shaped default input, which parity needs, and composes with `@doc`/`@spec` without rewriting definitions. (c) breaks the P9-2 brief and sync-mode parity for span metrics.
2. **Context propagation across processes.**
   - (a) `$callers` inheritance on by default, `Tracing.async` for spawn-time snapshots, and an explicit `context/0` + `with_context/2` hand-off for GenServers, Jido and `spawn`.
   - (b) Explicit hand-off only.
   - (c) (a) plus a `use DeepEvalEx.Tracing.GenServer` wrapper that carries the context through call and cast.

   **Recommended: (a).** It is closest to asyncio's implicit copying for Tasks and is explicit at the boundaries Python cannot cross either. Revisit (c) after P9.
3. **One carrier for Usage, the Ledger and the trace context.**
   - (a) Introduce the internal `DeepEvalEx.Scope` fork/join now, and make `Usage.async/await` and `Tracing.async/await` thin wrappers over it.
   - (b) Have `Tracing.async` call `Usage.async`.

   **Recommended: (a).** This is the third scope ADR-0009 decision 11 was waiting for.
4. **Relationship to OpenTelemetry.**
   - (a) No OTel dependency in P9; deepeval-shaped `:telemetry` metadata; an optional OTel GenAI bridge (`gen_ai.*` plus `confident.*` attributes, `opentelemetry_api` with `optional: true`, opt-in config) as a later unit or package.
   - (b) An optional `opentelemetry_api` bridge and GenAI semconv telemetry metadata in P9.
   - (c) Never support OTel.

   **Recommended: (a).** OTel has no parity surface, and semconv is still Development status. Decide later whether OTel *ingest* (P11) comes before the export bridge.
5. **Determinism of the trace fixtures.**
   - (a) Normalise uuids by first appearance and timestamps after a strict regex check, amend the fixture README, and check exact formatting with a Python-generated ISO table.
   - (b) Patch `uuid4` and `perf_counter` inside deepeval for exact bytes.

   **Recommended: (a).** (b) tests patched deepeval, not real deepeval.
6. **The default `evaluate_traced` mode and iterator semantics.**
   - (a) Default `:async`: no wrapper, one test case per captured trace, and the trace I/O from its root. `:sync` is opt-in with the wrapper and `children[0]` strip. Both are pinned by fixtures.
   - (b) Default `:sync`.

   **Recommended: (a).** It matches deepeval's `AsyncConfig(run_async=True)` default and Elixir's concurrent goldens.
7. **Async api-span order.**
   - (a) Run metrics concurrently but assemble buckets in deterministic BFS level order, with async fixtures limited to non-suspending metrics.
   - (b) Completion order, which reproduces asyncio's interleaving but is nondeterministic.

   **Recommended: (a).**
8. **Name of the nested dict on `DeepEvalEx.TestCase`.**
   - (a) `:trace_dict`, mirroring `_trace_dict`.
   - (b) `:trace`, as in the P9-5 brief.

   **Recommended: (a).** `:trace` already means the exported TraceApi on test-run test cases.
9. **Framework integrations.**
   - (a) A generic `TelemetryBridge` in-tree (P9-13), with Jido and LangChain-Elixir mappers as separate packages (`deep_eval_ex_jido`, `deep_eval_ex_langchain`) after P9.
   - (b) In-tree mappers compiled only when the library is loaded.
   - (c) Bridge only, with no first-party mappers.

   **Recommended: (a).** Upstream churn in event names never blocks a core release.
10. **Traces closed outside evaluation (OFF mode).**
    - (a) A `Sink` behaviour (`Sinks.Null` by default, `Sinks.Test`) plus `[:deep_eval_ex, :trace, :stop]`, with no retention.
    - (b) Also keep a bounded ETS ring buffer behind `Tracing.get_all_traces/0`.
    - (c) Telemetry only.

    **Recommended: (a).** It keeps memory bounded and leaves a seam for a later file or OTLP exporter.
11. **Spans still open when `capture/2` finishes.**
    - (a) Wait up to `:await_open` (default 5_000) for spans owned by live processes, then export them as `IN_PROGRESS` and emit a telemetry warning.
    - (b) Wait indefinitely, as deepeval does.

    **Recommended: (a).** A dead owner is already handled by the Store's monitor.
12. **Judge-call suppression.**
    - (a) `BaseMetric.measure/2` runs inside `Tracing.suppress/1`, and usage is still recorded.
    - (b) Let judge calls appear as LlmSpans.

    **Recommended: (a)**, matching deepeval's `_internal` observe.
13. **What marks a span ERRORED.**
    - (a) Only raise, throw or exit, as deepeval does.
    - (b) Also an `{:error, _}` return.
    - (c) (a) by default, with an opt-in `error_on: :error_tuple`.

    **Recommended: (a)** for P9, keeping (c) as a later extension.
14. **The `requires_trace?` callback shape.**
    - (a) `requires_trace?/0` plus an optional `/1` for struct metrics (GEval, JevEval), like `metric_name/0,1`.
    - (b) `/1` only.

    **Recommended: (a).**
15. **Struct shape.**
    - (a) One `%Span{type: ...}` with per-type Peri schemas.
    - (b) Five structs (`Span.Agent`, `Span.Llm`, ...).

    **Recommended: (a).** It is simpler for ETS rows, pattern matching and the bucket code. The cost is that dialyzer cannot catch a field set on the wrong type.

## References

- deepeval 4.3.1 (`_ref/deepeval`):
  - `deepeval/tracing/{types,tracing,context,trace_context,api,utils,trace_test_manager}.py`
  - `deepeval/tracing/otel/*`, `deepeval/tracing/offline_evals/*`
  - `deepeval/evaluate/execute/{agentic,loop,_common}.py`, `deepeval/evaluate/utils.py`
  - `deepeval/test_run/test_run.py` (`TraceMetricScores`)
  - `deepeval/metrics/utils/system_one.py` (`compact_trace`)
  - `deepeval/metrics/{task_completion,step_efficiency,plan_quality,plan_adherence,agent_loop_detection,g_eval}/`
  - `deepeval/integrations/*`
- Fixtures: `test/fixtures/deepeval/README.md`, `round_trip/traced_dataset`
- [ADR-0003](0003-telemetry-first-observability.md) Telemetry-First Observability
- [ADR-0004](0004-concurrent-evaluation-with-task-async-stream.md) Concurrent Evaluation with Task.async_stream
- [ADR-0007](0007-basemetric-macro-for-instrumentation.md) BaseMetric Macro for Automatic Instrumentation
- [ADR-0008](0008-peri-schema-validation-replacing-ecto.md) Peri Schema Validation Replacing Ecto
- [ADR-0009](0009-system-one-models-and-eval-modes.md) System One Models and Eval Modes (decision 11: carrying scope across tasks)
