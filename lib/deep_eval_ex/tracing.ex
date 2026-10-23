defmodule DeepEvalEx.Tracing do
  @moduledoc """
  Records what an agent does as a trace of spans: deepeval 4.3.1's
  `@observe` decorator, `Observer` and `trace()` context manager
  (`tracing/tracing.py`, `tracing/trace_context.py`), ADR-0011.

  Each traced call is a `DeepEvalEx.Tracing.Span`, nested under the span
  that was current when it started. The first span with no parent starts
  a `DeepEvalEx.Tracing.Trace`, which closes when its last open span
  does.

  ## Recording spans

  `deftraced` (see `DeepEvalEx.Tracing.Observe`) is the decorator: it
  defines a function whose every call is a span named after it, with the
  call's arguments as its default input and its result as its default
  output.

      defmodule MyApp.Support do
        use DeepEvalEx.Tracing

        deftraced answer(query), type: :agent, available_tools: ["retrieve"] do
          docs = retrieve(query)
          generate(query, docs)
        end

        deftraced retrieve(query, k \\\\ 2), type: :retriever do
          MyApp.Search.top_k(query, k)
        end
      end

  `span/3` records a block, and `open_span/2`, `close_span/2` and
  `record_span/2` are the primitives for adapters that see a call start
  and end in separate callbacks.

  A span is `:errored` when its function raises, throws or exits, with the
  exception's message (Python's `str(exc)`) or the inspected reason as its
  error; the original error is re-raised with its stacktrace. An
  `{:error, reason}` result is a successful span, as in deepeval.

  ## Span options

  - `:name` - The span's name (`deftraced`: the function's name)
  - `:input` - The span's default input, used when nothing set one
    (`deftraced`: the arguments)
  - `:metrics` - Metric specs to run on the span: a metric module,
    `{module, keyword}` or a metric struct
  - `:metric_collection`, `:metadata`, `:integration`
  - `:drop_if_root` - When `true`, no span is recorded unless one is
    already open, deepeval's `_drop_if_root` (for LLM adapters, so that a
    call outside any trace is not traced)
  - By type: `:available_tools` and `:agent_handoffs` (`:agent`);
    `:model`, `:provider`, `:prompt`, `:cost_per_input_token` and
    `:cost_per_output_token` (`:llm`); `:embedder` (`:retriever`);
    `:description` (`:tool`)

  The input and output defaults go through
  `DeepEvalEx.Tracing.JSON.make_serializable/1` and the configured mask
  (`DeepEvalEx.Tracing.JSON.mask/1`). When a root span closes, its default
  input and output become the trace's, unless they are already set.

  ## Across processes

  The trace context lives in the process dictionary (see
  `DeepEvalEx.Tracing.Ctx`):

  - `Task`, `Task.async_stream` and `Task.Supervisor` children join their
    caller's trace through `$callers`, looked up when their first span
    opens;
  - `async/1` and `await/2` take a snapshot when the task starts, and
    carry `DeepEvalEx.LLM.Usage` and the System One ledger too;
  - any other process (a `GenServer`, a bare `spawn`, a Jido agent) needs
    an explicit hand-off: pass `context/0` along and run the work in
    `with_context/2`.

        GenServer.call(planner, {:plan, goal, DeepEvalEx.Tracing.context()})

        def handle_call({:plan, goal, ctx}, _from, state),
          do: {:reply, DeepEvalEx.Tracing.with_context(ctx, fn -> plan(goal) end), state}

  ## Collecting traces

  `capture/2` runs a function and returns the traces it and its
  descendants started. Outside a capture a closed trace is only emitted
  as the `[:deep_eval_ex, :trace, :stop]` telemetry event.

      {_answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)

  `suppress/1` records nothing: `DeepEvalEx.Metrics.BaseMetric` measures
  inside it, so a metric's judge calls never appear in a user's trace, as
  deepeval's internal `observe`.

  ## Telemetry

  Emitted, never used to capture (ADR-0003); see `DeepEvalEx.Telemetry`:

  - `[:deep_eval_ex, :span, :start | :stop | :exception]`, shaped like
    `:telemetry.span/3`'s events, with `%{span: %Span{}, trace_uuid:,
    parent_uuid:, type:, telemetry_span_context:}` metadata
  - `[:deep_eval_ex, :trace, :stop]` with `%{trace: %Trace{}, route:
    :capture | :off}`, and `[:deep_eval_ex, :trace, :timeout]` for a
    trace `capture/2` stopped waiting for

  ## Python quirks kept

  - deepeval ends a trace when its first root span exits with no other
    span open, so two calls in a row inside one `trace/2` make two
    traces, and the trace's attributes go to the first.
  - A span opened under a parent that has since closed joins the nearest
    open ancestor, else the open trace, else a new one.
  - `trace/2` clears `llm_span_context/0` and `agent_span_context/0` when
    it returns, even inside an enclosing `trace/2` that set them, as
    deepeval resets them to empty contexts rather than the previous ones.

  ## Divergences

  - When `trace/2` started the trace and a span is still open in it as
    `fun` returns (a task's, or one opened with `open_span/2`), the trace
    stays open and the last span to close ends it. deepeval's `trace()`
    ends it at once, dropping the spans still to close.
  - A process that dies with spans open has them marked `:errored`, and
    their trace closes (see `DeepEvalEx.Tracing.Store`).
  """

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Scope
  alias DeepEvalEx.Tracing.{Ctx, Fields, JSON, Span, Store, Time, Trace}

  @typedoc "A span type."
  @type span_type :: Span.type()

  @typedoc "A metric to run on a span or trace."
  @type metric_spec :: Span.metric_spec()

  @span_fields [
    :name,
    :metrics,
    :metric_collection,
    :metadata,
    :integration,
    :available_tools,
    :agent_handoffs,
    :model,
    :provider,
    :cost_per_input_token,
    :cost_per_output_token,
    :embedder,
    :description
  ]

  # update_current_trace's fields that trace/2 takes, set when truthy.
  @trace_fields [
    :name,
    :tags,
    :metadata,
    :thread_id,
    :user_id,
    :input,
    :output,
    :retrieval_context,
    :context,
    :expected_output,
    :tools_called,
    :expected_tools
  ]

  @frames {__MODULE__, :frames}
  @llm_span_context {__MODULE__, :llm_span_context}
  @agent_span_context {__MODULE__, :agent_span_context}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import DeepEvalEx.Tracing.Observe,
        only: [deftraced: 2, deftraced: 3, defptraced: 2, defptraced: 3]
    end
  end

  ## Spans

  @doc """
  Runs `fun` as a span of `type` and returns its result.

  The result is the span's default output. See "Span options" in the
  moduledoc for `opts`; an option of another span type raises
  `ArgumentError`.

  ## Examples

      DeepEvalEx.Tracing.span(:tool, [name: "search", input: %{"q" => q}], fn ->
        MyApp.Search.run(q)
      end)
  """
  @spec span(span_type(), keyword(), (-> result)) :: result when result: term()
  def span(type, opts, fun) when is_function(fun, 0) do
    case open_span(type, opts) do
      :ignored ->
        fun.()

      {:ok, ctx} ->
        try do
          fun.()
        catch
          kind, reason ->
            close_span(ctx, exception: {kind, reason, __STACKTRACE__})
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          result ->
            close_span(ctx, output: result)
            result
        end
    end
  end

  @doc """
  Opens a span of `type` and makes it the current span, deepeval's
  `Observer.__enter__`; close it with `close_span/2` from the same
  process.

  Returns `{:ok, ctx}`, the span's context, or `:ignored` when nothing is
  recorded: under `suppress/1`, or with `drop_if_root: true` and no open
  span. Takes the options of `span/3`, plus `:start_us` (epoch
  microseconds) for a span that started earlier.
  """
  @spec open_span(span_type(), keyword()) :: {:ok, Ctx.t()} | :ignored
  def open_span(type, opts \\ []) do
    ctx = Ctx.current()

    case resolve(ctx) do
      :suppressed ->
        :ignored

      {nil, _trace_uuid} = resolved ->
        if Keyword.get(opts, :drop_if_root, false),
          do: :ignored,
          else: open(type, opts, ctx, resolved)

      resolved ->
        open(type, opts, ctx, resolved)
    end
  end

  defp open(type, opts, ctx, {parent, trace_uuid}) do
    # Validated before a trace is started for it.
    span = build_span(type, opts)
    route = route(ctx)
    {parent, trace_uuid} = join(parent, trace_uuid, route)

    span = %{
      span
      | trace_uuid: trace_uuid,
        parent_uuid: parent && parent.uuid,
        integration: span.integration || (parent && parent.integration)
    }

    Store.put_span(span)

    span_ctx = %Ctx{trace_uuid: trace_uuid, span_uuid: span.uuid, route: route}
    previous = Ctx.put(span_ctx)
    telemetry_ref = make_ref()

    frame = %{
      previous: previous,
      input: Keyword.get(opts, :input),
      prompt: Keyword.get(opts, :prompt),
      started: System.monotonic_time(),
      telemetry_ref: telemetry_ref
    }

    Process.put(@frames, Map.put(Process.get(@frames, %{}), span.uuid, frame))

    :telemetry.execute(
      [:deep_eval_ex, :span, :start],
      %{system_time: System.system_time(), monotonic_time: frame.started},
      metadata(span, telemetry_ref)
    )

    {:ok, span_ctx}
  end

  # Counts the span in its trace, or in a new one when there is none or the
  # trace closed since it was resolved.
  defp join(parent, nil, route), do: join(parent, Store.start_trace(route), route)

  defp join(parent, trace_uuid, route) do
    case Store.open_span(trace_uuid) do
      :ok -> {parent, trace_uuid}
      :closed -> join(nil, nil, route)
    end
  end

  defp build_span(type, opts) do
    attrs =
      opts
      |> Keyword.take(@span_fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(%{
        type: type,
        uuid: Store.uuid(),
        start_us: Keyword.get(opts, :start_us) || Time.now_us(),
        seq: System.unique_integer([:monotonic, :positive])
      })

    case Span.new(attrs) do
      {:ok, span} ->
        span

      {:error, errors} ->
        raise ArgumentError,
              "Invalid span: " <> Enum.map_join(errors, ", ", &"#{&1.key} #{&1.message}")
    end
  end

  # The open span a new span goes under and the open trace it joins.
  defp resolve(nil), do: {nil, nil}
  defp resolve(%Ctx{route: :suppressed}), do: :suppressed

  defp resolve(%Ctx{trace_uuid: trace_uuid, span_uuid: span_uuid}) when is_binary(span_uuid),
    do: open_ancestor(trace_uuid, span_uuid)

  defp resolve(%Ctx{trace_uuid: trace_uuid}) when is_binary(trace_uuid) do
    if Store.live?(trace_uuid), do: {nil, trace_uuid}, else: {nil, nil}
  end

  defp resolve(%Ctx{}), do: {nil, nil}

  defp open_ancestor(trace_uuid, nil), do: resolve(%Ctx{trace_uuid: trace_uuid})

  defp open_ancestor(trace_uuid, span_uuid) do
    case Store.fetch_span(trace_uuid, span_uuid) do
      %Span{status: :in_progress} = span -> {span, trace_uuid}
      %Span{parent_uuid: parent_uuid} -> open_ancestor(trace_uuid, parent_uuid)
      nil -> resolve(%Ctx{trace_uuid: trace_uuid})
    end
  end

  defp route(%Ctx{route: route}), do: route
  defp route(nil), do: :off

  @doc """
  Closes a span opened with `open_span/2` in this process, deepeval's
  `Observer.__exit__`, and restores the context it was opened in. When it
  was the trace's last open span, the trace closes.

  ## Options

  - `:output` - The span's default output (a function's result)
  - `:status` - `:success` (the default) or `:errored`
  - `:error` - The error text; makes the span `:errored`
  - `:exception` - `{kind, reason, stacktrace}` of what the span's code
    raised, threw or exited with: the span is `:errored` with its text
  - `:end_us` - The end time in epoch microseconds, by default now

  Raises `ArgumentError` for a span that is not open in this process.
  """
  @spec close_span(Ctx.t(), keyword()) :: :ok
  def close_span(%Ctx{trace_uuid: trace_uuid, span_uuid: span_uuid}, opts \\ []) do
    frame = pop_frame(span_uuid)
    {status, error} = outcome(opts)
    input = default(frame.input)
    output = default(Keyword.get(opts, :output))

    span =
      trace_uuid
      |> Store.fetch_span(span_uuid)
      |> Map.merge(%{
        status: status,
        error: error,
        end_us: Keyword.get(opts, :end_us) || Time.now_us()
      })
      |> put_default(:input, input)
      |> put_default(:output, output)
      |> put_prompt(frame.prompt)

    Store.put_span(span)
    if is_nil(span.parent_uuid), do: put_trace_defaults(trace_uuid, input, output)
    Ctx.put(frame.previous)
    emit_close(span, frame, Keyword.get(opts, :exception))

    case Store.close_span(trace_uuid) do
      0 -> Store.finish_trace(trace_uuid)
      # A counted span keeps its trace open (see Store's "Closing"), so this
      # is only a guard: never leave a row behind a closed trace.
      :closed -> Store.delete_span(trace_uuid, span_uuid)
      _open -> :ok
    end

    :ok
  end

  defp pop_frame(span_uuid) do
    case Map.pop(Process.get(@frames, %{}), span_uuid) do
      {nil, _frames} ->
        raise ArgumentError, "span #{inspect(span_uuid)} is not open in this process"

      {frame, frames} ->
        Process.put(@frames, frames)
        frame
    end
  end

  # Observer.__exit__: `if current_span.input is None`, and the same for output.
  defp put_default(span, key, value) do
    if is_nil(Map.fetch!(span, key)), do: Map.put(span, key, value), else: span
  end

  # A root span's defaults become the trace's, unless already set.
  defp put_trace_defaults(trace_uuid, input, output) do
    unless is_nil(input), do: Store.put_new_trace_attr(trace_uuid, :input, input)
    unless is_nil(output), do: Store.put_new_trace_attr(trace_uuid, :output, output)
  end

  defp outcome(opts) do
    case Keyword.fetch(opts, :exception) do
      {:ok, {kind, reason, stacktrace}} ->
        {:errored, error_text(kind, reason, stacktrace)}

      :error ->
        error = Keyword.get(opts, :error)
        default_status = if is_nil(error), do: :success, else: :errored
        {Keyword.get(opts, :status, default_status), error}
    end
  end

  # Python's str(exc) for an exception; the inspected reason otherwise.
  defp error_text(:error, reason, stacktrace),
    do: :error |> Exception.normalize(reason, stacktrace) |> Exception.message()

  defp error_text(_kind, reason, _stacktrace), do: inspect(reason)

  defp default(value), do: value |> JSON.make_serializable() |> JSON.mask()

  # An LLM span takes its `:prompt` option unless one was set.
  defp put_prompt(%Span{type: :llm, prompt: nil} = span, prompt), do: %{span | prompt: prompt}
  defp put_prompt(span, _prompt), do: span

  defp emit_close(span, frame, exception) do
    now = System.monotonic_time()
    measurements = %{duration: now - frame.started, monotonic_time: now}
    metadata = metadata(span, frame.telemetry_ref)

    case exception do
      {kind, reason, stacktrace} ->
        :telemetry.execute(
          [:deep_eval_ex, :span, :exception],
          measurements,
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

      nil ->
        :telemetry.execute([:deep_eval_ex, :span, :stop], measurements, metadata)
    end
  end

  defp metadata(span, telemetry_ref) do
    %{
      span: span,
      trace_uuid: span.trace_uuid,
      parent_uuid: span.parent_uuid,
      type: span.type,
      telemetry_span_context: telemetry_ref
    }
  end

  @doc """
  Records a span that has already finished, under the current span: an
  `open_span/2` and `close_span/2` in one call. Takes the options of
  both, with `:start_us` and `:end_us` for its times.
  """
  @spec record_span(span_type(), keyword()) :: :ok
  def record_span(type, opts \\ []) do
    case open_span(type, opts) do
      {:ok, ctx} -> close_span(ctx, Keyword.take(opts, [:output, :status, :error, :end_us]))
      :ignored -> :ok
    end
  end

  ## Traces

  @doc """
  Runs `fun` inside a trace, deepeval's `trace()` context manager: the
  current trace when one is open, else a new one, which closes when
  `fun` returns unless a span closed it first (see "Python quirks kept").

  ## Options

  - `:name`, `:tags`, `:metadata`, `:thread_id`, `:user_id`, `:input`,
    `:output`, `:retrieval_context`, `:context`, `:expected_output`,
    `:tools_called`, `:expected_tools`, `:metrics` and
    `:metric_collection` - Set on the trace when truthy in Python's sense
    (`nil`, `false`, `""`, `[]`, `%{}` and `0` set nothing), as
    `update_current_trace`
  - `:llm_span_context`, `:agent_span_context` - Keyword lists LLM
    adapters and agent integrations read while `fun` runs (see
    `llm_span_context/0`), deepeval's `LlmSpanContext` and
    `AgentSpanContext`. As in deepeval, each is set only when given,
    so a nested `trace/2` without one keeps the enclosing one, and both
    are cleared when `fun` returns, also inside an enclosing `trace/2`

  A trace `trace/2` started closes when `fun` returns only if no span is
  open in it; otherwise the last span to close ends it (see
  "Divergences").
  """
  @spec trace(keyword(), (-> result)) :: result when result: term()
  def trace(opts, fun) when is_function(fun, 0) do
    ctx = Ctx.current()

    case resolve(ctx) do
      :suppressed -> fun.()
      {_parent, trace_uuid} -> in_trace(ctx, trace_uuid, opts, fun)
    end
  end

  defp in_trace(ctx, trace_uuid, opts, fun) do
    started? = is_nil(trace_uuid)
    trace_uuid = trace_uuid || Store.start_trace(route(ctx))
    put_trace_attrs(trace_uuid, opts)
    %Ctx{} = ctx = ctx || %Ctx{}
    previous = Ctx.put(%{ctx | trace_uuid: trace_uuid})
    put_span_context(@llm_span_context, Keyword.get(opts, :llm_span_context))
    put_span_context(@agent_span_context, Keyword.get(opts, :agent_span_context))

    try do
      fun.()
    after
      if started?, do: Store.finish_trace(trace_uuid)
      Ctx.put(previous)
      # deepeval resets both to empty contexts, not to the enclosing ones.
      Process.delete(@llm_span_context)
      Process.delete(@agent_span_context)
    end
  end

  # deepeval sets current_llm_context and current_agent_context only when
  # one is given (a dataclass is always truthy, even empty), so an inner
  # trace() without one keeps the outer one.
  defp put_span_context(_key, nil), do: :ok
  defp put_span_context(key, context), do: Process.put(key, context)

  defp put_trace_attrs(trace_uuid, opts) do
    [:metrics, :metric_collection | @trace_fields]
    |> Enum.map(&{&1, Keyword.get(opts, &1)})
    |> Enum.filter(fn {_field, value} -> Fields.truthy?(value) end)
    |> Enum.each(fn {field, value} ->
      Store.put_trace_attr(trace_uuid, field, trace_value(field, value))
    end)
  end

  defp trace_value(field, tools) when field in [:tools_called, :expected_tools],
    do: Enum.map(tools, &tool_call/1)

  defp trace_value(_field, value), do: value

  defp tool_call(%ToolCall{} = tool), do: tool

  defp tool_call(attrs) do
    case ToolCall.new(attrs) do
      {:ok, tool} -> tool
      {:error, errors} -> raise ArgumentError, "Invalid tool call: #{inspect(errors)}"
    end
  end

  @doc """
  The `:llm_span_context` of the enclosing `trace/2`, or `nil`.
  """
  @spec llm_span_context() :: keyword() | nil
  def llm_span_context, do: Process.get(@llm_span_context)

  @doc """
  The `:agent_span_context` of the enclosing `trace/2`, or `nil`.
  """
  @spec agent_span_context() :: keyword() | nil
  def agent_span_context, do: Process.get(@agent_span_context)

  @doc """
  Runs `fun` without recording any span or trace, in this process or the
  tasks it starts, as deepeval's internal `observe`.
  """
  @spec suppress((-> result)) :: result when result: term()
  def suppress(fun) when is_function(fun, 0), do: Ctx.with(%Ctx{route: :suppressed}, fun)

  ## Across processes

  @doc """
  The current trace context, to hand to another process for
  `with_context/2`, or `nil`.
  """
  @spec context() :: Ctx.t() | nil
  def context, do: Ctx.current()

  @doc """
  Runs `fun` with `ctx` (from `context/0`, maybe in another process) as
  the current context, restoring the previous one afterwards, also when
  `fun` raises. With `nil`, `fun` runs outside any trace, cut off from
  its `$callers`' context too.
  """
  @spec with_context(Ctx.t() | nil, (-> result)) :: result when result: term()
  def with_context(ctx, fun) when is_function(fun, 0), do: Ctx.with(ctx || %Ctx{}, fun)

  @doc """
  Starts `fun` in a `Task` with a snapshot of the current trace context;
  collect its result with `await/2`.

  As `DeepEvalEx.LLM.Usage.async/1`, the task also records its LLM usage
  for the caller and works on a copy of the caller's System One ledger.
  """
  @spec async((-> term())) :: Task.t()
  defdelegate async(fun), to: Scope

  @doc """
  Awaits a task started with `async/1` and returns its result, passing
  its usage and ledger on to the caller (see
  `DeepEvalEx.LLM.Usage.await/2`).
  """
  @spec await(Task.t(), timeout()) :: term()
  defdelegate await(task, timeout \\ 5_000), to: Scope

  ## Capture

  @doc """
  Runs `fun` and returns `{result, traces}`: every trace started by `fun`,
  and by the processes it starts that find its context, in start order.

  Spans in `fun` start traces of their own even inside an open span. A
  trace still open when `fun` returns is waited for, up to `:await_open`
  milliseconds (default `5_000`); after that it is returned as it stands,
  `:in_progress`, and `[:deep_eval_ex, :trace, :timeout]` is emitted. It
  then goes nowhere when it closes.

  The traces arrive through the tracing store, never the caller's
  mailbox, so a `GenServer` or LiveView can capture.
  """
  @spec capture(keyword(), (-> result)) :: {result, [Trace.t()]} when result: term()
  def capture(opts, fun) when is_list(opts) and is_function(fun, 0) do
    ref = make_ref()
    await_open = Keyword.get(opts, :await_open, 5_000)

    try do
      Ctx.with(%Ctx{route: ref}, fun)
    catch
      kind, reason ->
        discard(ref)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result -> {result, collect(ref, System.monotonic_time(:millisecond) + await_open)}
    end
  end

  defp collect(ref, deadline) do
    await_closed(ref, deadline, 1)
    Enum.map(Store.route_traces(ref), &take(ref, &1))
  end

  defp await_closed(ref, deadline, pause) do
    open = Enum.reject(Store.route_traces(ref), &Store.closed?(ref, &1))
    remaining = deadline - System.monotonic_time(:millisecond)

    if open != [] and remaining > 0 do
      Process.sleep(min(pause, remaining))
      await_closed(ref, deadline, min(pause * 2, 50))
    end
  end

  # The snapshot comes first: a trace closing after `take_closed/2`
  # forgets its route goes :off, and is then returned as it stood.
  defp take(ref, trace_uuid) do
    snapshot = Store.snapshot(trace_uuid)

    case Store.take_closed(ref, trace_uuid) do
      %Trace{} = trace ->
        trace

      nil ->
        :telemetry.execute(
          [:deep_eval_ex, :trace, :timeout],
          %{system_time: System.system_time()},
          %{trace: snapshot}
        )

        snapshot
    end
  end

  defp discard(ref) do
    for trace_uuid <- Store.route_traces(ref), do: Store.take_closed(ref, trace_uuid)
    :ok
  end
end
