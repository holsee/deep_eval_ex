defmodule DeepEvalEx.Tracing.Store do
  @moduledoc """
  Where open traces live while spans are recorded: deepeval 4.3.1's
  `trace_manager` (`active_traces`, `active_spans`, `start_new_trace`,
  `end_trace`), as one public ETS table.

  The store is a `GenServer` under the application supervisor that owns
  the table and monitors each process that records spans, once, when it
  first does. Spans are read and written by the recording processes
  themselves, so the store does no other work on the hot path. The rows:

  - `{{:trace, trace_uuid}, meta}` - an open trace: its owner, route,
    start time and start order
  - `{{:span, trace_uuid, span_uuid}, owner, %Span{}}` - written by the
    owner, the process that opened the span, and changed in place by
    `update_span/3` from any process (`update_current_span` from a task
    that joined through `$callers`)
  - `{{:trace_attr, trace_uuid, field}, value}` - one row per trace
    field set while the trace is open, so concurrent writers keep each
    other's fields
  - `{{:open, trace_uuid}, count}` - the trace's open spans
  - `{{:pid, pid}, ctx}` - each process's `DeepEvalEx.Tracing.Ctx`, for
    the `$callers` lookup
  - `{{:pending, ref}, owner, payload}` - a slot staged by
    `DeepEvalEx.Tracing.next_span/2` and its typed variants, taken by the
    first span that matches it, in any process (see
    `DeepEvalEx.Tracing.Pending`)
  - `{{:route_trace, ref, trace_uuid}, seq}` and
    `{{:closed, ref, trace_uuid}, %Trace{}}` - the traces a
    `DeepEvalEx.Tracing.capture/2` waits for, and those it can collect.
    Closed traces reach their capturer through the table, never its
    mailbox

  ## Closing

  A trace closes when its last open span closes. The closing process
  builds it with `DeepEvalEx.Tracing.Tree.build/3`, deletes its rows and
  routes it: to its capture, or, without one, only to the
  `[:deep_eval_ex, :trace, :stop]` event.

  Spans of other processes (tasks that found the trace through
  `$callers`) can join it as it closes. The closer claims the trace by
  deleting its `:open` row only while the count is 0, so a span counted
  first keeps it open, and a span counted later finds no row and starts
  a trace of its own; no counted span's row is ever deleted under it.

  ## Divergence: dead owners

  When a process dies with spans still open, the store marks them
  `:errored`, with the exit reason (`Exception.format_exit/1`) as their
  error, and closes their trace once nothing else is open in it.
  deepeval would keep such a trace open forever.

  ## Configuration

  Span and trace uuids are random version 4 uuids; tests can replace the
  generator with a `{module, function}` or a zero-arity function:

      config :deep_eval_ex, :tracing, uuid: {MyApp.Ids, :next}
  """

  use GenServer

  alias DeepEvalEx.Tracing.{Ctx, Span, Time, Trace, Tree}

  @table __MODULE__
  @watched {__MODULE__, :watched}

  @typedoc "An open trace's row: who started it, where it goes, when it started."
  @type meta :: %{owner: pid(), route: Ctx.route(), start_us: integer(), seq: integer()}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, MapSet.new()}
  end

  @doc false
  @impl true
  def handle_call({:watch, pid}, _from, watched) do
    if MapSet.member?(watched, pid) do
      {:reply, :ok, watched}
    else
      Process.monitor(pid)
      {:reply, :ok, MapSet.put(watched, pid)}
    end
  end

  @doc false
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, watched) do
    reap(pid, reason)
    {:noreply, MapSet.delete(watched, pid)}
  end

  @doc """
  A new span or trace uuid, from the configured `:uuid` generator (see
  "Configuration") or a random version 4 uuid.
  """
  @spec uuid() :: String.t()
  def uuid do
    case Keyword.get(Application.get_env(:deep_eval_ex, :tracing, []), :uuid) do
      nil -> uuid4()
      {module, function} -> apply(module, function, [])
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :rand.bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end

  ## Traces

  @doc """
  Starts a trace owned by the calling process, routed to `route`, and
  returns its uuid; `start_new_trace`.
  """
  @spec start_trace(Ctx.route()) :: String.t()
  def start_trace(route) do
    trace_uuid = uuid()
    seq = System.unique_integer([:monotonic, :positive])
    meta = %{owner: self(), route: route, start_us: Time.now_us(), seq: seq}

    :ets.insert(@table, [{{:trace, trace_uuid}, meta}, {{:open, trace_uuid}, 0}])
    if is_reference(route), do: :ets.insert(@table, {{:route_trace, route, trace_uuid}, seq})
    watch()
    trace_uuid
  end

  @doc "Whether the trace is still open."
  @spec live?(String.t()) :: boolean()
  def live?(trace_uuid), do: :ets.member(@table, {:trace, trace_uuid})

  @doc "Sets a field of an open trace."
  @spec put_trace_attr(String.t(), atom(), term()) :: :ok
  def put_trace_attr(trace_uuid, field, value) do
    :ets.insert(@table, {{:trace_attr, trace_uuid, field}, value})
    :ok
  end

  @doc "Sets a field of an open trace unless it is already set."
  @spec put_new_trace_attr(String.t(), atom(), term()) :: :ok
  def put_new_trace_attr(trace_uuid, field, value) do
    :ets.insert_new(@table, {{:trace_attr, trace_uuid, field}, value})
    :ok
  end

  @doc """
  Sets fields of an open trace, `update_current_trace`: a `nil` value
  unsets its field. Returns `:closed`, writing nothing, when the trace has
  closed; a field written as it closes is removed again, so no row
  outlives its trace.
  """
  @spec update_trace(String.t(), [{atom(), term()}]) :: :ok | :closed
  def update_trace(trace_uuid, attrs) do
    if live?(trace_uuid) do
      Enum.each(attrs, fn
        {field, nil} -> :ets.delete(@table, {:trace_attr, trace_uuid, field})
        {field, value} -> put_trace_attr(trace_uuid, field, value)
      end)

      if live?(trace_uuid),
        do: :ok,
        else: Enum.each(attrs, &:ets.delete(@table, {:trace_attr, trace_uuid, elem(&1, 0)}))
    else
      :closed
    end
  end

  @doc """
  Closes the trace if no span is open in it and no other process already
  closed it: builds it with `status` and routes it (see the moduledoc).

  The open count is removed only while it is 0, in one step, so a span
  that joined after the last one closed keeps the trace open (and closes
  it in turn), and a span that comes later finds it closed (see
  "Closing").
  """
  @spec finish_trace(String.t(), Span.status()) :: :ok
  def finish_trace(trace_uuid, status \\ :success) do
    with 1 <- :ets.select_delete(@table, [{{{:open, trace_uuid}, 0}, [], [true]}]),
         [{_key, meta}] <- :ets.take(@table, {:trace, trace_uuid}) do
      trace = assemble(trace_uuid, meta, status, Time.now_us())
      delete_rows(trace_uuid)
      deliver(trace, meta)
    else
      _open_or_closed -> :ok
    end
  end

  @doc """
  The open trace as it stands, `:in_progress` and without an end time,
  or `nil` once it has closed. Nothing is changed.
  """
  @spec snapshot(String.t()) :: Trace.t() | nil
  def snapshot(trace_uuid) do
    case :ets.lookup(@table, {:trace, trace_uuid}) do
      [{_key, meta}] -> assemble(trace_uuid, meta, :in_progress, nil)
      [] -> nil
    end
  end

  defp assemble(trace_uuid, meta, status, end_us) do
    spans = :ets.select(@table, [{{{:span, trace_uuid, :_}, :_, :"$1"}, [], [:"$1"]}])

    attrs =
      :ets.select(@table, [{{{:trace_attr, trace_uuid, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])

    %Trace{uuid: trace_uuid, status: status, start_us: meta.start_us, end_us: end_us}
    |> struct(attrs)
    |> Tree.build(spans)
  end

  defp delete_rows(trace_uuid) do
    :ets.match_delete(@table, {{:span, trace_uuid, :_}, :_, :_})
    :ets.match_delete(@table, {{:trace_attr, trace_uuid, :_}, :_})
  end

  defp deliver(%Trace{uuid: trace_uuid} = trace, %{route: ref}) when is_reference(ref) do
    if :ets.member(@table, {:route_trace, ref, trace_uuid}) do
      :ets.insert(@table, {{:closed, ref, trace_uuid}, trace})
      emit_stop(trace, :capture)
    else
      emit_stop(trace, :off)
    end
  end

  defp deliver(trace, _meta), do: emit_stop(trace, :off)

  defp emit_stop(trace, route) do
    duration = System.convert_time_unit(trace.end_us - trace.start_us, :microsecond, :native)

    :telemetry.execute([:deep_eval_ex, :trace, :stop], %{duration: duration}, %{
      trace: trace,
      route: route
    })
  end

  ## Spans

  @doc """
  Writes a span's row, owned by `owner` (the calling process by default).
  """
  @spec put_span(Span.t(), pid()) :: :ok
  def put_span(%Span{trace_uuid: trace_uuid, uuid: span_uuid} = span, owner \\ self()) do
    :ets.insert(@table, {{:span, trace_uuid, span_uuid}, owner, span})
    if owner == self(), do: watch()
    :ok
  end

  @doc """
  Changes a span of an open trace in place with `fun` and returns
  `{:ok, span}`, the changed span, or `:error` when there is no such span.

  Any process can call it: the row is replaced only if it is still the one
  `fun` was given (compare and swap), else `fun` runs again on the new
  one, so neither the owner's close nor another process's update is lost.
  """
  @spec update_span(String.t(), String.t(), (Span.t() -> Span.t())) :: {:ok, Span.t()} | :error
  def update_span(trace_uuid, span_uuid, fun) do
    key = {:span, trace_uuid, span_uuid}

    case :ets.lookup(@table, key) do
      [] ->
        :error

      [{^key, _owner, span}] ->
        swap(key, span, fun.(span), fn -> update_span(trace_uuid, span_uuid, fun) end)
    end
  end

  # Replaces the row only while it still holds `span`, else retries.
  defp swap(_key, span, span, _retry), do: {:ok, span}

  defp swap(key, span, updated, retry) do
    match = [
      {{key, :"$1", :"$2"}, [{:"=:=", :"$2", {:const, span}}],
       [{{{:const, key}, :"$1", {:const, updated}}}]}
    ]

    if :ets.select_replace(@table, match) == 1, do: {:ok, updated}, else: retry.()
  end

  @doc "A span of an open trace, or `nil`."
  @spec fetch_span(String.t(), String.t()) :: Span.t() | nil
  def fetch_span(trace_uuid, span_uuid) do
    case :ets.lookup(@table, {:span, trace_uuid, span_uuid}) do
      [{_key, _owner, span}] -> span
      [] -> nil
    end
  end

  @doc """
  Counts a newly opened span of the trace, or returns `:closed` when the
  trace closed since it was looked up.
  """
  @spec open_span(String.t()) :: :ok | :closed
  def open_span(trace_uuid) do
    :ets.update_counter(@table, {:open, trace_uuid}, 1)
    :ok
  rescue
    ArgumentError -> :closed
  end

  @doc """
  Counts a closed span of the trace and returns how many are still open,
  or `:closed` when the trace has already closed without it.
  """
  @spec close_span(String.t()) :: integer() | :closed
  def close_span(trace_uuid) do
    :ets.update_counter(@table, {:open, trace_uuid}, -1)
  rescue
    ArgumentError -> :closed
  end

  @doc "Removes a span's row."
  @spec delete_span(String.t(), String.t()) :: :ok
  def delete_span(trace_uuid, span_uuid) do
    :ets.delete(@table, {:span, trace_uuid, span_uuid})
    :ok
  end

  ## The $callers index

  @doc false
  @spec index_pid(pid(), Ctx.t()) :: :ok
  def index_pid(pid, ctx) do
    :ets.insert(@table, {{:pid, pid}, ctx})
    watch()
    :ok
  end

  @doc false
  @spec unindex_pid(pid()) :: :ok
  def unindex_pid(pid) do
    :ets.delete(@table, {:pid, pid})
    :ok
  end

  @doc false
  @spec pid_ctx(pid()) :: Ctx.t() | nil
  def pid_ctx(pid) do
    case :ets.lookup(@table, {:pid, pid}) do
      [{_key, ctx}] -> ctx
      [] -> nil
    end
  end

  ## Pending slots

  @doc false
  # Stages a next_* slot, owned by the calling process.
  @spec put_pending(reference(), keyword()) :: :ok
  def put_pending(ref, payload) do
    :ets.insert(@table, {{:pending, ref}, self(), payload})
    watch()
    :ok
  end

  @doc false
  # Takes a slot's payload, once: `nil` when it is gone or already taken.
  @spec take_pending(reference()) :: keyword() | nil
  def take_pending(ref) do
    case :ets.take(@table, {:pending, ref}) do
      [{_key, _owner, payload}] -> payload
      [] -> nil
    end
  end

  @doc false
  @spec delete_pending(reference()) :: :ok
  def delete_pending(ref) do
    :ets.delete(@table, {:pending, ref})
    :ok
  end

  ## Capture

  @doc false
  # The traces started under a capture, in start order.
  @spec route_traces(reference()) :: [String.t()]
  def route_traces(ref) do
    @table
    |> :ets.select([{{{:route_trace, ref, :"$1"}, :"$2"}, [], [{{:"$2", :"$1"}}]}])
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  @doc false
  @spec closed?(reference(), String.t()) :: boolean()
  def closed?(ref, trace_uuid), do: :ets.member(@table, {:closed, ref, trace_uuid})

  @doc false
  # Collects a closed trace, removing it and its route.
  @spec take_closed(reference(), String.t()) :: Trace.t() | nil
  def take_closed(ref, trace_uuid) do
    forget(ref, trace_uuid)

    case :ets.take(@table, {:closed, ref, trace_uuid}) do
      [{_key, trace}] -> trace
      [] -> nil
    end
  end

  @doc false
  # Stops routing the trace to its capture: when it closes, it goes :off.
  @spec forget(reference(), String.t()) :: :ok
  def forget(ref, trace_uuid) do
    :ets.delete(@table, {:route_trace, ref, trace_uuid})
    :ok
  end

  ## Owners

  # Once per process, and synchronously, so a process that dies right
  # after its first span is reaped with its own exit reason.
  defp watch do
    unless Process.get(@watched) do
      GenServer.call(__MODULE__, {:watch, self()})
      Process.put(@watched, true)
    end
  end

  defp reap(pid, reason) do
    :ets.delete(@table, {:pid, pid})
    :ets.match_delete(@table, {{:pending, :_}, pid, :_})
    error = Exception.format_exit(reason)
    now = Time.now_us()

    @table
    |> :ets.select([{{{:span, :_, :_}, pid, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.status == :in_progress))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.each(fn span ->
      put_span(%{span | status: :errored, error: error, end_us: now}, pid)

      case close_span(span.trace_uuid) do
        0 -> finish_trace(span.trace_uuid)
        :closed -> delete_span(span.trace_uuid, span.uuid)
        _open -> :ok
      end
    end)

    @table
    |> :ets.select([{{{:trace, :"$1"}, %{owner: pid}}, [], [:"$1"]}])
    |> Enum.each(&finish_trace/1)
  end
end
