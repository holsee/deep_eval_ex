defmodule DeepEvalEx.Tracing.TelemetryBridge do
  @moduledoc """
  Records spans from another library's `:telemetry.span/3` events: the
  generic seam for what deepeval 4.3.1's `integrations/*` patch into each
  Python framework (ADR-0011, decision 9). Mappers for particular
  libraries (Jido, LangChain) are left to separate packages.

  `attach/3` handles a prefix's `:start`, `:stop` and `:exception` events
  with a mapper that turns each into a span action:

      DeepEvalEx.Tracing.TelemetryBridge.attach(:my_agent, [:my_app, :agent, :step], fn
        :start, _measurements, %{tool: tool} = meta -> {:tool, name: tool, input: meta.args}
        :start, _measurements, meta -> {:agent, name: meta.agent}
        :stop, _measurements, meta -> {:update, output: meta.result}
        _phase, _measurements, _meta -> :skip
      end)

  ## Actions

  On `:start`:

  - `{type, opts}` - Opens a span of `type` (`:base`, `:agent`, `:llm`,
    `:retriever` or `:tool`) with `DeepEvalEx.Tracing.span/3`'s options,
    `:drop_if_root` included
  - `{:update, opts}` - Sets fields of the current span, as below
  - `:skip` - Nothing

  On `:stop` and `:exception`, for a span opened on its `:start` (the
  mapper is not called otherwise):

  - `{:update, opts}` - `:output` is the span's result, as a `deftraced`
    function's: its default output, and its trace's when it is a root
    span. The other options set fields of the span: those of
    `DeepEvalEx.Tracing.update_current_span/1`, and those of the span's
    typed update (`update_llm_span/1` for an `:llm` span, ...), so token
    counts known only at the end can be set
  - `:skip` - Nothing, and the span has no result

  Then the span closes: `:errored` on `:exception`, with the error text of
  its `:kind` and `:reason` metadata, as `span/3`'s.

  ## Processes and pairing

  Handlers run in the emitting process, so a span joins the span open
  there, or the trace a `Task` finds through `$callers` (see "Across
  processes" in `DeepEvalEx.Tracing`), with no hand-off. A `:stop` closes
  the span of the `:start` with the same `telemetry_span_context`, as
  `:telemetry.span/3` sets it; events without one pair innermost first.

  ## Errors

  A mapper that raises, or returns an invalid action, is logged and
  counts as `:skip`; a span opened on `:start` still closes. The handler
  is never detached for it, as `:telemetry` would detach a raising one.
  """

  require Logger

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Ctx, Update}

  @typedoc "The phase of a `:telemetry.span/3` event."
  @type phase :: :start | :stop | :exception

  @typedoc "What a mapper returns for an event; see \"Actions\"."
  @type action :: {Tracing.span_type(), keyword()} | {:update, keyword()} | :skip

  @typedoc "Maps an event's phase, measurements and metadata to an action."
  @type mapper :: (phase(), map(), map() -> action())

  @span_types [:base, :agent, :llm, :retriever, :tool]

  @doc """
  Attaches a handler, named `handler_id`, to `prefix ++ [:start]`,
  `[:stop]` and `[:exception]`. Returns `{:error, :already_exists}` when a
  bridge with that id is attached.
  """
  @spec attach(term(), [atom()], mapper()) :: :ok | {:error, :already_exists}
  def attach(handler_id, prefix, mapper) when is_list(prefix) and is_function(mapper, 3) do
    :telemetry.attach_many(
      {__MODULE__, handler_id},
      Enum.map([:start, :stop, :exception], &(prefix ++ [&1])),
      &__MODULE__.handle_event/4,
      %{id: handler_id, mapper: mapper}
    )
  end

  @doc """
  Detaches the bridge named `handler_id`. Spans it opened that are still
  open stay open until their process exits.
  """
  @spec detach(term()) :: :ok | {:error, :not_found}
  def detach(handler_id), do: :telemetry.detach({__MODULE__, handler_id})

  @doc false
  def handle_event(event, measurements, metadata, config) do
    key = {config.id, Map.get(metadata, :telemetry_span_context)}

    case List.last(event) do
      :start -> start(key, measurements, metadata, config)
      phase when phase in [:stop, :exception] -> stop(phase, key, measurements, metadata, config)
    end
  end

  defp start(key, measurements, metadata, config) do
    entry = safely(config, fn -> on_start(config.mapper.(:start, measurements, metadata)) end)
    push(key, entry || :none)
  end

  defp on_start({:update, opts}) when is_list(opts) do
    Tracing.update_current_span(opts)
    :none
  end

  defp on_start({type, opts}) when type in @span_types and is_list(opts) do
    case Tracing.open_span(type, opts) do
      {:ok, ctx} -> {ctx, type}
      :ignored -> :none
    end
  end

  defp on_start(:skip), do: :none
  defp on_start(other), do: invalid!(other)

  defp stop(phase, key, measurements, metadata, config) do
    case pop(key) do
      {ctx, type} ->
        output =
          safely(config, fn ->
            on_stop(config.mapper.(phase, measurements, metadata), ctx, type)
          end)

        Tracing.close_span(ctx, [output: output] ++ close_opts(phase, metadata))

      _none ->
        :ok
    end
  end

  defp on_stop({:update, opts}, ctx, type) when is_list(opts), do: update(ctx, type, opts)
  defp on_stop(:skip, _ctx, _type), do: nil
  defp on_stop(other, _ctx, _type), do: invalid!(other)

  defp invalid!(action), do: raise(ArgumentError, "invalid action: #{inspect(action)}")

  # Sets the other options on the span and returns :output, the span's
  # result.
  defp update(ctx, type, opts) do
    {output, opts} = Keyword.pop(opts, :output)
    {typed, base} = Keyword.split(opts, Update.typed_keys(type))

    Ctx.with(ctx, fn ->
      Tracing.update_current_span(base)
      if typed != [], do: update_typed(type, typed)
    end)

    output
  end

  defp update_typed(:agent, opts), do: Tracing.update_agent_span(opts)
  defp update_typed(:llm, opts), do: Tracing.update_llm_span(opts)
  defp update_typed(:retriever, opts), do: Tracing.update_retriever_span(opts)
  defp update_typed(:tool, opts), do: Tracing.update_tool_span(opts)

  defp close_opts(:stop, _metadata), do: []

  defp close_opts(:exception, %{kind: kind, reason: reason} = metadata),
    do: [exception: {kind, reason, Map.get(metadata, :stacktrace, [])}]

  defp close_opts(:exception, _metadata), do: [status: :errored]

  # Runs the mapper's part of a handler, logging what it raises: a raising
  # handler would be detached by :telemetry.
  defp safely(config, fun) do
    fun.()
  catch
    kind, reason ->
      Logger.error(
        "DeepEvalEx.Tracing.TelemetryBridge #{inspect(config.id)} skipped an event:\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      nil
  end

  # The spans opened on :start, by bridge and telemetry_span_context, the
  # innermost first; :none for a start that opened nothing.
  defp push(key, entry) do
    Process.put({__MODULE__, key}, [entry | Process.get({__MODULE__, key}, [])])
  end

  defp pop(key) do
    case Process.get({__MODULE__, key}, []) do
      [] ->
        nil

      [entry] ->
        Process.delete({__MODULE__, key})
        entry

      [entry | rest] ->
        Process.put({__MODULE__, key}, rest)
        entry
    end
  end
end
