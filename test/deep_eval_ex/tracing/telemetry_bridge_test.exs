defmodule DeepEvalEx.Tracing.TelemetryBridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Span, TelemetryBridge, Trace}

  # Each test bridges its own event prefix, so async tests never see each
  # other's events.
  setup context do
    prefix = [:bridge_test, context.test]
    on_exit(fn -> TelemetryBridge.detach(context.test) end)
    %{prefix: prefix, id: context.test}
  end

  # The ADR's example mapper: a tool step becomes a :tool span, any other
  # step an :agent span, and the result their output.
  defp agent_mapper do
    fn
      :start, _measurements, %{tool: tool} = meta -> {:tool, name: tool, input: meta.args}
      :start, _measurements, meta -> {:agent, name: meta.agent}
      :stop, _measurements, meta -> {:update, output: meta.result}
      _phase, _measurements, _meta -> :skip
    end
  end

  defp step(prefix, meta, fun) do
    :telemetry.span(prefix, meta, fn ->
      result = fun.()
      {result, Map.put(meta, :result, result)}
    end)
  end

  test "records :telemetry.span events as nested spans", %{prefix: prefix, id: id} do
    assert :ok = TelemetryBridge.attach(id, prefix, agent_mapper())

    {answer, [trace]} =
      Tracing.capture([], fn ->
        step(prefix, %{agent: "planner"}, fn ->
          weather =
            step(prefix, %{tool: "weather", args: %{"city" => "Paris"}}, fn -> "sunny" end)

          "It is #{weather}"
        end)
      end)

    assert answer == "It is sunny"

    assert %Trace{
             status: :success,
             output: "It is sunny",
             root_spans: [
               %Span{
                 type: :agent,
                 name: "planner",
                 output: "It is sunny",
                 children: [
                   %Span{
                     type: :tool,
                     name: "weather",
                     input: %{"city" => "Paris"},
                     output: "sunny",
                     status: :success
                   }
                 ]
               }
             ]
           } = trace
  end

  test "joins the span that is open in the emitting process", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, agent_mapper())

    {_, [trace]} =
      Tracing.capture([], fn ->
        Tracing.span(:agent, [name: "app"], fn ->
          [1, 2]
          |> Task.async_stream(fn n ->
            step(prefix, %{tool: "t#{n}", args: n}, fn -> n * 10 end)
          end)
          |> Enum.map(fn {:ok, result} -> result end)
        end)
      end)

    assert [%Span{name: "app", children: children}] = trace.root_spans
    assert children |> Enum.map(&{&1.name, &1.output}) |> Enum.sort() == [{"t1", 10}, {"t2", 20}]
  end

  test "records nothing for a skipped start, and ignores its stop", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, %{traced: true} -> {:base, name: "kept"}
      :start, _m, _meta -> :skip
      :stop, _m, meta -> {:update, output: meta.result}
    end)

    {_, [trace]} =
      Tracing.capture([], fn ->
        step(prefix, %{traced: true}, fn ->
          step(prefix, %{traced: false}, fn -> "inner" end)
          "outer"
        end)
      end)

    assert [%Span{name: "kept", output: "outer", children: []}] = trace.root_spans
  end

  test "an :exception event makes the span errored", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, agent_mapper())

    {_, [trace]} =
      Tracing.capture([], fn ->
        assert_raise RuntimeError, fn ->
          step(prefix, %{agent: "fragile"}, fn -> raise "boom" end)
        end
      end)

    assert %Trace{status: :errored, root_spans: [root]} = trace
    assert %Span{name: "fragile", status: :errored, error: "boom"} = root
  end

  test "pairs start and stop without a span context, innermost first", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, meta -> {:base, name: meta.name}
      _phase, _m, meta -> {:update, output: meta.name}
    end)

    {_, [trace]} =
      Tracing.capture([], fn ->
        :telemetry.execute(prefix ++ [:start], %{}, %{name: "outer"})
        :telemetry.execute(prefix ++ [:start], %{}, %{name: "inner"})
        :telemetry.execute(prefix ++ [:stop], %{}, %{name: "inner"})
        :telemetry.execute(prefix ++ [:exception], %{}, %{name: "outer"})
      end)

    assert [%Span{name: "outer", status: :errored, output: "outer", children: [inner]}] =
             trace.root_spans

    assert %Span{name: "inner", status: :success, output: "inner"} = inner
  end

  test "sets the span's typed fields on stop", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, meta ->
        {:llm, name: "chat", model: meta.model, input: meta.prompt}

      :stop, _m, meta ->
        {:update, output: meta.result, input_token_count: 3, output_token_count: 5}
    end)

    {_, [trace]} =
      Tracing.capture([], fn ->
        step(prefix, %{model: "gpt-4o", prompt: "hi"}, fn -> "hello" end)
      end)

    assert [%Span{type: :llm, model: "gpt-4o", input: "hi", output: "hello"} = span] =
             trace.root_spans

    assert {span.input_token_count, span.output_token_count} == {3.0, 5.0}
  end

  test "a start :update enriches the current span", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, meta -> {:update, metadata: %{"step" => meta.step}}
      _phase, _m, _meta -> :skip
    end)

    {_, [trace]} =
      Tracing.capture([], fn ->
        Tracing.span(:base, [name: "host"], fn ->
          step(prefix, %{step: "fetch"}, fn -> :ok end)
        end)
      end)

    assert [%Span{name: "host", metadata: %{"step" => "fetch"}, children: []}] = trace.root_spans
  end

  test "keeps drop_if_root: no span outside a trace", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, _meta -> {:llm, name: "call", drop_if_root: true}
      _phase, _m, _meta -> :skip
    end)

    assert {:ok, []} = Tracing.capture([], fn -> step(prefix, %{}, fn -> :ok end) end)
  end

  test "logs a mapper that raises, still closes the span and stays attached",
       %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, %{bad: true} -> raise "bad start"
      :start, _m, _meta -> {:base, name: "step"}
      :stop, _m, _meta -> raise "bad stop"
    end)

    log =
      capture_log(fn ->
        {_, [trace]} = Tracing.capture([], fn -> step(prefix, %{}, fn -> :ok end) end)
        assert [%Span{name: "step", status: :success}] = trace.root_spans

        assert {:ok, []} =
                 Tracing.capture([], fn -> step(prefix, %{bad: true}, fn -> :ok end) end)
      end)

    assert log =~ "bad stop"
    assert log =~ "bad start"
    assert id in Enum.map(:telemetry.list_handlers(prefix), &elem(&1.id, 1))
  end

  test "an invalid span from the mapper is logged and skipped", %{prefix: prefix, id: id} do
    TelemetryBridge.attach(id, prefix, fn
      :start, _m, _meta -> {:tool, []}
      _phase, _m, _meta -> :skip
    end)

    log =
      capture_log(fn ->
        {_, [trace]} =
          Tracing.capture([], fn ->
            Tracing.span(:base, [name: "host"], fn -> step(prefix, %{}, fn -> :ok end) end)
          end)

        assert [%Span{name: "host", children: []}] = trace.root_spans
      end)

    assert log =~ "Invalid span"
  end

  test "attach refuses a taken id, and detach stops recording", %{prefix: prefix, id: id} do
    assert :ok = TelemetryBridge.attach(id, prefix, agent_mapper())
    assert {:error, :already_exists} = TelemetryBridge.attach(id, prefix, agent_mapper())

    assert :ok = TelemetryBridge.detach(id)
    assert {:error, :not_found} = TelemetryBridge.detach(id)

    assert {"done", []} =
             Tracing.capture([], fn -> step(prefix, %{agent: "a"}, fn -> "done" end) end)
  end
end
