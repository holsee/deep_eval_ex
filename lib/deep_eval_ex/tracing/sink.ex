defmodule DeepEvalEx.Tracing.Sink do
  @moduledoc """
  Where a trace closed outside any `DeepEvalEx.Tracing.capture/2` goes:
  the seam where deepeval 4.3.1's `trace_manager.post_trace` sends every
  trace to Confident AI (ADR-0011, decision 10).

  DeepEvalEx posts nowhere and keeps no closed trace. The configured sink
  gets each one instead, then the `[:deep_eval_ex, :trace, :stop]` event
  is emitted with `route: :off`. A captured trace goes to its capture,
  never to the sink.

  ## Configuration

      # The default: traces are dropped
      config :deep_eval_ex, :tracing, sink: DeepEvalEx.Tracing.Sinks.Null

      # Your own sink, as a module or {module, opts}
      config :deep_eval_ex, :tracing, sink: {MyApp.TraceFile, path: "traces.jsonl"}

  `DeepEvalEx.Tracing.Sinks.Test` sends each trace to a test process.

  ## Writing a sink

      defmodule MyApp.TraceFile do
        @behaviour DeepEvalEx.Tracing.Sink

        @impl true
        def export(trace, opts) do
          json = trace |> DeepEvalEx.Tracing.Api.trace_api() |> Jason.encode!()
          File.write(Keyword.fetch!(opts, :path), [json, ?\\n], [:append])
        end
      end

  `c:export/2` runs in the process that closed the trace's last span, so
  traced code waits for it: a slow sink should hand the trace to a
  process of its own. A trace whose owner died is closed, and exported,
  by `DeepEvalEx.Tracing.Store`'s process. A sink that raises, throws,
  exits or returns `{:error, reason}` is logged; the traced code carries
  on.

  As deepeval posts no dropped trace, a trace marked with
  `DeepEvalEx.Tracing.drop_current_trace/0` never reaches the sink.
  """

  require Logger

  alias DeepEvalEx.Tracing.{Sinks, Trace}

  @doc """
  Exports a closed trace. `opts` are the options of the `{module, opts}`
  config, `[]` for a bare module.
  """
  @callback export(trace :: Trace.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  The configured sink as `{module, opts}`; `DeepEvalEx.Tracing.Sinks.Null`
  when none is.
  """
  @spec configured() :: {module(), keyword()}
  def configured do
    case Keyword.get(Application.get_env(:deep_eval_ex, :tracing, []), :sink) do
      nil -> {Sinks.Null, []}
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc false
  # Hands a trace closed outside a capture to the configured sink, unless
  # it is dropped; a failing sink is logged, never raised.
  @spec export(Trace.t()) :: :ok
  def export(%Trace{drop: true}), do: :ok

  def export(%Trace{} = trace) do
    {module, opts} = configured()

    try do
      module.export(trace, opts)
    catch
      kind, reason ->
        Logger.error(
          "DeepEvalEx tracing sink #{inspect(module)} failed to export trace " <>
            "#{trace.uuid}:\n" <> Exception.format(kind, reason, __STACKTRACE__)
        )
    else
      {:error, reason} ->
        Logger.error(
          "DeepEvalEx tracing sink #{inspect(module)} failed to export trace " <>
            "#{trace.uuid}: #{inspect(reason)}"
        )

      _ok ->
        :ok
    end

    :ok
  end
end
