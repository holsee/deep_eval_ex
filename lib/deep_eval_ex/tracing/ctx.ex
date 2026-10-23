defmodule DeepEvalEx.Tracing.Ctx do
  @moduledoc """
  A process's trace context: deepeval 4.3.1's `current_span_context` and
  `current_trace_context` (`tracing/context.py`), held in the process
  dictionary instead of `ContextVar`s.

  - `:trace_uuid` - The trace new spans join, when it is still open
  - `:span_uuid` - The current span, the parent of the next one
  - `:route` - Where a trace started under this context goes when it
    closes: a `DeepEvalEx.Tracing.capture/2` reference, `:off` (no
    capture: only the `[:deep_eval_ex, :trace, :stop]` event) or
    `:suppressed` (no span is recorded, see
    `DeepEvalEx.Tracing.suppress/1`)
  - `:pending` - The slots `DeepEvalEx.Tracing.next_span/2` and its typed
    variants staged for the next span of a type, by type (see
    `DeepEvalEx.Tracing.Pending`)

  ## Resolution

  `current/0` returns the process's own context, else the context of the
  nearest `$callers` ancestor that has one, else `nil`. `Task`,
  `Task.async_stream` and `Task.Supervisor` children so join their
  caller's trace with no code, as asyncio copies the `ContextVar`s into a
  task. The ancestor is looked up when the child's first span opens, not
  when the child starts; `DeepEvalEx.Tracing.async/1` takes a snapshot
  when it starts instead. A process outside `$callers` (a `GenServer`, a
  bare `spawn`) needs an explicit hand-off with
  `DeepEvalEx.Tracing.context/0` and `DeepEvalEx.Tracing.with_context/2`.

  A context names spans and traces; whether they are still open is the
  store's business: a span opened under a closed parent joins the
  nearest open ancestor, else the trace, else a new trace.
  """

  alias DeepEvalEx.Tracing.Store

  @typedoc "Where a closed trace goes; see the moduledoc."
  @type route :: reference() | :off | :suppressed

  @type t :: %__MODULE__{
          trace_uuid: String.t() | nil,
          span_uuid: String.t() | nil,
          route: route(),
          pending: %{optional(DeepEvalEx.Tracing.Span.type()) => reference()}
        }

  defstruct trace_uuid: nil, span_uuid: nil, route: :off, pending: %{}

  @key {__MODULE__, :ctx}

  @doc """
  The current context: the process's own, else the nearest `$callers`
  ancestor's, else `nil`.
  """
  @spec current() :: t() | nil
  def current do
    case Process.get(@key) do
      nil -> Enum.find_value(Process.get(:"$callers", []), &Store.pid_ctx/1)
      ctx -> ctx
    end
  end

  @doc """
  Sets the process's own context (`nil` clears it) and returns the
  previous one, for `put/1` to restore. Descendants find it through the
  store's `$callers` index.
  """
  @spec put(t() | nil) :: t() | nil
  def put(nil) do
    Store.unindex_pid(self())
    Process.delete(@key)
  end

  def put(%__MODULE__{} = ctx) do
    Store.index_pid(self(), ctx)
    Process.put(@key, ctx)
  end

  @doc """
  Runs `fun` with `ctx` as the process's own context, restoring the
  previous one afterwards, also when `fun` raises.
  """
  @spec with(t() | nil, (-> result)) :: result when result: term()
  def with(ctx, fun) do
    previous = put(ctx)

    try do
      fun.()
    after
      put(previous)
    end
  end
end
