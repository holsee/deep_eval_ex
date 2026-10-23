# Tracing

An agent is more than its final answer: it retrieves, calls tools and asks
an LLM, often from several processes. DeepEvalEx records those steps as a
**trace** of **spans**, as Python deepeval 4.3.1 does with `@observe`, so
that each step can later be inspected and evaluated.

> Exporting a trace in deepeval's `TraceApi` shape and evaluating traces
> with metrics are not available yet. This guide covers recording them.

## Traced functions

`deftraced` defines a function whose every call is a span. It is
deepeval's `@observe` decorator:

```elixir
defmodule MyApp.Support do
  use DeepEvalEx.Tracing

  @doc "Answers a support question."
  @spec answer(String.t()) :: String.t()
  deftraced answer(query), type: :agent, available_tools: ["retrieve"] do
    docs = retrieve(query)
    generate(query, docs)
  end

  deftraced retrieve(query, k \\ 2), type: :retriever, embedder: "text-embedding-3-small" do
    MyApp.Search.top_k(query, k)
  end

  deftraced generate(query, documents), type: :llm, model: "gpt-4o-mini" do
    MyApp.LLM.answer(query, documents)
  end
end
```

Each span is named after its function. Its input is the call's arguments,
in order and with defaults applied (`retrieve("q")` records
`{"query": "q", "k": 2}`), and its output is the result. The span types are
`:base` (the default), `:agent`, `:llm`, `:retriever` and `:tool`; each
takes its own options (`:available_tools`, `:model`, `:embedder`,
`:description`, ...), but not `:input`: the arguments are the input.
`defptraced` defines a private function.

A function with several clauses keeps one head and lists its clauses in
the body, so each call is one span:

```elixir
deftraced classify(input), type: :tool do
  text when is_binary(text) -> {:text, text}
  _other -> :unknown
end
```

Such a body cannot also have `rescue`, `catch`, `else` or `after`; put
them in a function the clauses call.

`DeepEvalEx.Tracing.span/3` records a block instead, and
`open_span/2`, `close_span/2` and `record_span/2` are the primitives for
code that sees a step start and end in separate callbacks.

### Errors

A span whose code raises, throws or exits is `:errored`, with the
exception's message as its error, and the error is re-raised unchanged.
As in deepeval, a returned `{:error, reason}` is a successful span.

## Capturing traces

`DeepEvalEx.Tracing.capture/2` runs a function and returns the traces it
started:

```elixir
{answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)

[root] = trace.root_spans
root.name                          #=> "answer"
Enum.map(root.children, & &1.name) #=> ["retrieve", "generate"]
```

A trace closes when its last open span closes. Its input and output are
its root span's, and an errored root span makes the trace `:errored`. Spans
started in a row, each with no parent, make one trace each. Outside a
capture, a closed trace is emitted as the `[:deep_eval_ex, :trace, :stop]`
telemetry event (see the [Telemetry](Telemetry.md) guide) and kept nowhere.

`DeepEvalEx.Tracing.trace/2` groups spans into a trace and sets its
attributes (`name`, `tags`, `metadata`, `thread_id`, `user_id`, ...), as
deepeval's `trace()` context manager. Like deepeval, it ends the trace when
its first root span closes. Unlike deepeval, a trace that `trace/2` started
stays open past the block while a span in it is still open (a task's), and
the last span to close ends it. The `:llm_span_context` and
`:agent_span_context` options are set for the block when given and cleared
when it returns, as in deepeval.

## Exporting traces

`DeepEvalEx.Tracing.Api.trace_api/2` turns a captured trace into
deepeval's `TraceApi`, the JSON deepeval posts for a trace and writes as a
test case's `trace` in `test_run_<timestamp>.json`:

```elixir
{_answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)

trace
|> DeepEvalEx.Tracing.Api.trace_api()
|> DeepEvalEx.TestRun.JSON.encode!(indent: 2)
```

Spans are grouped by type into `baseSpans`, `agentSpans`, `llmSpans`,
`retrieverSpans` and `toolSpans`, in deepeval's order, with UTC times
truncated to milliseconds. A dropped span is left out and its children
take its parent. A span's metrics appear as `metricsData`: pass measured
results per span uuid with `metrics_data: %{uuid => [metric_data]}`;
without them each metric is written unmeasured (`success: false`), as
deepeval exports a trace outside evaluation.

In a test run, `traceMetricsScores` sums the span metric results per span
type, span name and metric (`DeepEvalEx.TestRun.TraceMetricScores`), and
the same results count in `metricsScores`.

### Nested and compact traces

Metrics that judge a whole agent run read the trace as deepeval's nested
trace dict, which `DeepEvalEx.Tracing.NestedDict.build/1` builds from a
root span: each span's fields by name (`input`, `output`,
`tools_called`, `model`, ...), without ids, times, status, metadata or
metric data, and its children under `"children"`. `DeepEvalEx.TestCase`'s
`:trace_dict` field holds it for those metrics, as deepeval's private
`_trace_dict`, and is never exported. `NestedDict.to_json/2` renders it
as the JSON those metrics put in their prompts:

```elixir
{_answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)

trace_dict = DeepEvalEx.Tracing.NestedDict.build(hd(trace.root_spans))
IO.puts(DeepEvalEx.Tracing.NestedDict.to_json(trace_dict))
```

`DeepEvalEx.Tracing.CompactTrace.compact/1` cuts the dict down to what a
System One model is asked about: each span's name, type, description,
inputs, outputs, error, model, contexts and tool calls, with empty values
left out and tool calls as their Python `str()`.

## Updating spans and traces

Code running in a span can add to it, as deepeval's `update_current_span`
and friends do:

```elixir
deftraced retrieve(query), type: :retriever do
  docs = MyApp.Search.top_k(query, 3)
  DeepEvalEx.Tracing.update_current_span(retrieval_context: docs, metadata: %{"index" => "faq"})
  DeepEvalEx.Tracing.update_retriever_span(top_k: 3)
  docs
end

deftraced generate(query, docs), type: :llm, model: "gpt-4o-mini" do
  {:ok, text, usage} = MyApp.LLM.chat(query, docs)
  DeepEvalEx.Tracing.update_llm_span(input_token_count: usage.input, output_token_count: usage.output)
  DeepEvalEx.Tracing.update_current_trace(name: "support", user_id: "user-1", output: text)
  text
end
```

- `update_current_span/1` sets the current span's `:input`, `:output`,
  `:retrieval_context`, `:context`, `:expected_output`, `:tools_called`,
  `:expected_tools`, `:metadata`, `:name`, `:metrics`, ... An input or
  output set here wins over the arguments and the result. A `:test_case`
  (a `DeepEvalEx.TestCase`) sets the span's input, output, expected output,
  contexts and tool calls in one go.
- `update_llm_span/1`, `update_agent_span/1`, `update_tool_span/1` and
  `update_retriever_span/1` set a span type's own fields, and do nothing
  when the current span has another type.
- `update_current_trace/1` sets the trace's `:name`, `:tags`, `:metadata`,
  `:thread_id`, `:user_id`, `:input`, `:output`, test-case fields and
  metrics, from any process in the trace.
- `drop_current_span/0` and `drop_current_trace/0` mark the span or trace
  to be left out of exports.

As in deepeval, a value sets nothing when it is falsy in Python's sense:
`nil`, `false`, `""`, `[]`, `%{}` and `0`. So `output: 0` is ignored. Token
counts, costs and the agent and tool fields are the exception: zero and
empty lists are set there, as deepeval checks those for `None` only.

### Staging the next span

Some spans run code you do not own, such as the LLM call inside a library.
`next_span/2` and its typed variants stage fields for the next span of a
type while a function runs. They are deepeval's `next_*_span` context
managers, written as functions:

```elixir
DeepEvalEx.Tracing.next_llm_span([model: "gpt-4o", metadata: %{"step" => "plan"}], fn ->
  MyApp.Agent.run(question)
end)
```

The first `:llm` span opened inside the function takes the staged fields
when it opens, and later spans get nothing. A typed slot's fields win over
`next_span/2`'s, which any span type takes. `update_current_span/1` can
still override them. A task the function starts can take the slot too, but
only one span ever does.

## Across processes

The trace context lives in the process dictionary, and is found from
other processes like this:

- **Tasks** (`Task.async`, `Task.async_stream`, `Task.Supervisor`) join
  their caller's trace with no extra code, through `$callers`. The caller's
  span is looked up when the task's first span opens.
- **`DeepEvalEx.Tracing.async/1`** and **`await/2`** take the context when
  the task starts, and also carry the LLM usage and System One state that
  metrics track.
- **Any other process** (a `GenServer`, a Jido agent, a bare `spawn`) needs
  the context handed over:

```elixir
GenServer.call(planner, {:plan, goal, DeepEvalEx.Tracing.context()})

def handle_call({:plan, goal, ctx}, _from, state) do
  {:reply, DeepEvalEx.Tracing.with_context(ctx, fn -> plan(goal) end), state}
end
```

A process that dies with spans open has them marked `:errored` with its
exit reason, and their trace closes. A trace still open when `capture/2`'s
function returns is waited for, up to `:await_open` milliseconds (5,000 by
default), then returned `:in_progress`.

Captured traces travel through the tracing store, not the capturer's
mailbox, so a `GenServer` or LiveView can capture without receiving
stray messages.

## Metrics are not traced

Metrics measure inside `DeepEvalEx.Tracing.suppress/1`, so the LLM calls a
judge makes never show up in your traces. Use `suppress/1` yourself for
work you do not want recorded.

## Configuration

```elixir
config :deep_eval_ex, :tracing,
  # Applied to every default input and output, as deepeval's mask
  mask: {MyApp.Redact, :redact}
```

`clock:` and `uuid:` replace the time and id sources, for tests.
