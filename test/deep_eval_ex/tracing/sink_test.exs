defmodule DeepEvalEx.Tracing.SinkTest do
  # Changes the :tracing application config, which every closing trace reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Sink, Sinks, Span, Trace}

  defmodule Raising do
    @behaviour DeepEvalEx.Tracing.Sink

    @impl true
    def export(_trace, _opts), do: raise("sink down")
  end

  defmodule Failing do
    @behaviour DeepEvalEx.Tracing.Sink

    @impl true
    def export(_trace, _opts), do: {:error, :unreachable}
  end

  defmodule Forwarding do
    @behaviour DeepEvalEx.Tracing.Sink

    # Configured as a bare module: gets no options.
    @impl true
    def export(trace, opts) do
      send(Application.fetch_env!(:deep_eval_ex, :sink_test_pid), {:forwarded, trace, opts})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:deep_eval_ex, :tracing)

    on_exit(fn ->
      Application.delete_env(:deep_eval_ex, :sink_test_pid)

      if previous,
        do: Application.put_env(:deep_eval_ex, :tracing, previous),
        else: Application.delete_env(:deep_eval_ex, :tracing)
    end)
  end

  defp use_sink(sink), do: Application.put_env(:deep_eval_ex, :tracing, sink: sink)

  test "sends a trace closed outside a capture to the configured sink" do
    use_sink({Sinks.Test, pid: self()})

    Tracing.span(:agent, [name: "sink_off"], fn -> :ok end)

    assert_receive {:trace, %Trace{status: :success, root_spans: [%Span{name: "sink_off"}]}}
  end

  test "keeps a captured trace from the sink" do
    use_sink({Sinks.Test, pid: self()})

    {_, [%Trace{}]} =
      Tracing.capture([], fn -> Tracing.span(:base, [name: "sink_captured"], fn -> :ok end) end)

    refute_receive {:trace, %Trace{root_spans: [%Span{name: "sink_captured"}]}}, 50
  end

  test "keeps a dropped trace from the sink, as deepeval posts no dropped trace" do
    use_sink({Sinks.Test, pid: self()})
    ref = :telemetry_test.attach_event_handlers(self(), [[:deep_eval_ex, :trace, :stop]])

    Tracing.span(:base, [name: "sink_dropped"], fn -> Tracing.drop_current_trace() end)

    assert_receive {[:deep_eval_ex, :trace, :stop], ^ref, _,
                    %{
                      route: :off,
                      trace: %Trace{drop: true, root_spans: [%{name: "sink_dropped"}]}
                    }}

    refute_receive {:trace, %Trace{root_spans: [%Span{name: "sink_dropped"}]}}, 50
    :telemetry.detach(ref)
  end

  test "sends a trace a capture stopped waiting for to the sink when it closes" do
    use_sink({Sinks.Test, pid: self()})

    {ctx, [%Trace{status: :in_progress}]} =
      Tracing.capture([await_open: 0], fn ->
        {:ok, ctx} = Tracing.open_span(:base, name: "sink_late")
        ctx
      end)

    refute_receive {:trace, _}, 20
    Tracing.close_span(ctx)

    assert_receive {:trace, %Trace{status: :success, root_spans: [%Span{name: "sink_late"}]}}
  end

  test "calls a sink configured as a module with no options" do
    Application.put_env(:deep_eval_ex, :sink_test_pid, self())
    use_sink(Forwarding)

    Tracing.span(:base, [name: "sink_module"], fn -> :ok end)

    assert_receive {:forwarded, %Trace{root_spans: [%Span{name: "sink_module"}]}, []}
  end

  test "logs a sink that raises, and the traced code carries on" do
    use_sink(Raising)

    log =
      capture_log(fn ->
        assert Tracing.span(:base, [name: "sink_raises"], fn -> :done end) == :done
      end)

    assert log =~ "DeepEvalEx.Tracing.SinkTest.Raising"
    assert log =~ "sink down"
  end

  test "logs a sink that returns an error" do
    use_sink(Failing)

    log = capture_log(fn -> Tracing.span(:base, [name: "sink_fails"], fn -> :ok end) end)

    assert log =~ "DeepEvalEx.Tracing.SinkTest.Failing"
    assert log =~ ":unreachable"
  end

  test "defaults to the null sink" do
    Application.delete_env(:deep_eval_ex, :tracing)

    assert Sink.configured() == {Sinks.Null, []}
    assert Sinks.Null.export(%Trace{uuid: "t"}, []) == :ok
    assert Tracing.span(:base, [name: "sink_null"], fn -> :ok end) == :ok
  end

  test "reads the sink from the :tracing config" do
    use_sink(Sinks.Null)
    assert Sink.configured() == {Sinks.Null, []}

    use_sink({Sinks.Test, pid: self()})
    assert Sink.configured() == {Sinks.Test, pid: self()}
  end
end
