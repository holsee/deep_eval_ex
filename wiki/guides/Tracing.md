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
`:description`, ...). `defptraced` defines a private function.

A function with several clauses keeps one head and lists its clauses in
the body, so each call is one span:

```elixir
deftraced classify(input), type: :tool do
  text when is_binary(text) -> {:text, text}
  _other -> :unknown
end
```

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
its first root span closes.

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
