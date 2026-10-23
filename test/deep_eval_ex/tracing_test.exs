defmodule DeepEvalEx.TracingTest do
  # The tracing store is one global table; every test works on its own
  # traces, so they run concurrently.
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.{Result, TestCase, Tracing}
  alias DeepEvalEx.SystemOne.Ledger
  alias DeepEvalEx.Tracing.{Ctx, Span, Store, Trace}

  defmodule SpanningMetric do
    @moduledoc false
    # A metric whose measure opens a span, as an adapter's judge call will.
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "Spanning"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, _opts) do
      Tracing.span(:llm, [name: "judge"], fn -> :judged end)
      task = Task.async(fn -> Tracing.span(:llm, [name: "judge task"], fn -> :ok end) end)
      Task.await(task)
      {:ok, Result.new(metric: metric_name(), score: 1.0, threshold: 0.5)}
    end
  end

  defmodule Planner do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call({:plan, goal, ctx}, _from, state) do
      plan =
        Tracing.with_context(ctx, fn ->
          Tracing.span(:agent, [name: "planner", input: goal], fn -> "plan for #{goal}" end)
        end)

      {:reply, plan, state}
    end
  end

  defp capture(fun, opts \\ []), do: Tracing.capture(opts, fun)

  defp names(spans), do: Enum.map(spans, & &1.name)

  defp rows(trace_uuid) do
    :ets.select(Store, [
      {{{:_, trace_uuid, :_}, :_, :_}, [], [:"$_"]},
      {{{:_, trace_uuid, :_}, :_}, [], [:"$_"]},
      {{{:_, trace_uuid}, :_}, [], [:"$_"]}
    ])
  end

  describe "span/3" do
    test "records nested spans of one trace and returns the result" do
      {result, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent", available_tools: ["search"]], fn ->
            Tracing.span(:tool, [name: "search", input: %{"q" => "x"}], fn -> ["doc"] end)
            Tracing.span(:llm, [name: "generate", model: "gpt-4o-mini"], fn -> "answer" end)
            "done"
          end)
        end)

      assert result == "done"
      assert %Trace{status: :success, root_spans: [agent]} = trace
      assert is_binary(trace.uuid)
      assert trace.start_us <= trace.end_us

      assert %Span{type: :agent, name: "agent", status: :success, parent_uuid: nil} = agent
      assert agent.available_tools == ["search"]
      assert agent.output == "done"
      assert names(agent.children) == ["search", "generate"]

      [search, generate] = agent.children
      assert search.input == %{"q" => "x"}
      assert search.output == ["doc"]
      assert search.parent_uuid == agent.uuid
      assert generate.model == "gpt-4o-mini"
      assert Enum.all?([agent, search, generate], &(&1.trace_uuid == trace.uuid))
      assert agent.start_us <= search.start_us and search.end_us <= agent.end_us
      assert agent.seq < search.seq and search.seq < generate.seq

      # The tool child fills the agent's tools_called.
      assert [%{name: "search", input_parameters: %{"q" => "x"}, output: ["doc"]}] =
               agent.tools_called
    end

    test "sets the trace's input and output from its root span" do
      {_, [trace]} =
        capture(fn -> Tracing.span(:base, [name: "root", input: {:q, 1}], fn -> :ok end) end)

      # Defaults go through make_json_serializable, as deepeval's sync observe.
      assert {trace.input, trace.output} == {["q", 1], "ok"}
      assert hd(trace.root_spans).input == ["q", 1]
    end

    test "leaves the input nil without an :input" do
      {_, [trace]} = capture(fn -> Tracing.span(:base, [name: "root"], fn -> nil end) end)
      assert [%Span{input: nil, output: nil}] = trace.root_spans
      assert {trace.input, trace.output} == {nil, nil}
    end

    test "marks a raising span ERRORED and re-raises with the original stacktrace" do
      parent = self()

      {_, [trace]} =
        capture(fn ->
          try do
            Tracing.span(:agent, [name: "agent"], fn -> raise ArgumentError, "planner crashed" end)
          rescue
            error -> send(parent, {:raised, error, __STACKTRACE__})
          end
        end)

      assert_received {:raised, %ArgumentError{message: "planner crashed"}, [frame | _]}
      assert {__MODULE__, _fun, _arity, _location} = frame

      assert trace.status == :errored
      assert [%Span{status: :errored, error: "planner crashed", output: nil}] = trace.root_spans
    end

    test "marks thrown and exited spans ERRORED with the inspected reason" do
      {_, traces} =
        capture(fn ->
          assert catch_throw(Tracing.span(:base, [name: "t"], fn -> throw(:stop) end)) == :stop

          assert catch_exit(Tracing.span(:base, [name: "e"], fn -> exit({:shutdown, 1}) end)) ==
                   {:shutdown, 1}
        end)

      assert [[%Span{error: ":stop"}], [%Span{error: "{:shutdown, 1}"}]] =
               Enum.map(traces, & &1.root_spans)

      assert Enum.all?(traces, &(&1.status == :errored))
    end

    test "keeps the parent and trace successful when a child's raise is caught" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            try do
              Tracing.span(:tool, [name: "flaky"], fn -> raise "upstream timeout" end)
            rescue
              _ -> "recovered"
            end
          end)
        end)

      assert trace.status == :success
      [agent] = trace.root_spans
      assert agent.status == :success
      assert [%Span{status: :errored, error: "upstream timeout"}] = agent.children
      assert [%{name: "flaky", output: nil}] = agent.tools_called
    end

    test "does not treat an {:error, _} result as an error" do
      {_, [trace]} =
        capture(fn -> Tracing.span(:tool, [name: "t"], fn -> {:error, :nope} end) end)

      assert [%Span{status: :success, output: ["error", "nope"]}] = trace.root_spans
    end

    test "starts a trace per top-level span, in start order" do
      {_, traces} =
        capture(fn ->
          Tracing.span(:agent, [name: "first"], fn -> 1 end)
          Tracing.span(:agent, [name: "second"], fn -> 2 end)
        end)

      assert Enum.map(traces, &names(&1.root_spans)) == [["first"], ["second"]]
      assert [a, b] = Enum.map(traces, & &1.uuid)
      assert a != b
    end

    test "skips a span with drop_if_root: true when no span is open" do
      {result, traces} =
        capture(fn ->
          outside = Tracing.span(:llm, [name: "adapter", drop_if_root: true], fn -> :untraced end)

          inside =
            Tracing.span(:agent, [name: "agent"], fn ->
              Tracing.span(:llm, [name: "adapter", drop_if_root: true], fn -> :traced end)
            end)

          {outside, inside}
        end)

      assert result == {:untraced, :traced}
      assert [%Trace{root_spans: [agent]}] = traces
      assert names(agent.children) == ["adapter"]
    end

    test "inherits the parent's integration" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a", integration: "jido"], fn ->
            Tracing.span(:tool, [name: "t"], fn -> :ok end)
            Tracing.span(:tool, [name: "u", integration: "own"], fn -> :ok end)
          end)
        end)

      assert Enum.map(hd(trace.root_spans).children, & &1.integration) == ["jido", "own"]
    end

    test "sets an LLM span's prompt from its options" do
      prompt = %{"alias" => "support", "version" => "00.00.01"}

      {_, [trace]} =
        capture(fn -> Tracing.span(:llm, [name: "gen", prompt: prompt], fn -> "x" end) end)

      assert [%Span{prompt: ^prompt}] = trace.root_spans
    end

    test "raises ArgumentError on options a span type does not take" do
      assert_raise ArgumentError, ~r/Invalid span/, fn ->
        Tracing.span(:tool, [], fn -> :ok end)
      end

      assert_raise ArgumentError, ~r/is not a field of an :agent span/, fn ->
        Tracing.span(:agent, [name: "a", model: "gpt-4o"], fn -> :ok end)
      end

      assert Tracing.context() == nil
    end

    test "leaves nothing behind in the store or the mailbox" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            Tracing.span(:tool, [name: "t"], fn -> :ok end)
          end)
        end)

      assert rows(trace.uuid) == []
      assert :ets.lookup(Store, {:pid, self()}) == []
      assert Process.info(self(), :messages) == {:messages, []}
      assert Tracing.context() == nil
    end
  end

  describe "open_span/2, close_span/2 and record_span/2" do
    test "open and close a span by hand" do
      {_, [trace]} =
        capture(fn ->
          {:ok, ctx} = Tracing.open_span(:agent, name: "agent")
          assert Tracing.context() == ctx
          {:ok, child} = Tracing.open_span(:tool, name: "t", input: "q")
          :ok = Tracing.close_span(child, output: "r")
          assert Tracing.context() == ctx
          :ok = Tracing.close_span(ctx, status: :errored, error: "gave up")
        end)

      assert [%Span{status: :errored, error: "gave up", children: [tool]}] = trace.root_spans
      assert {tool.input, tool.output, tool.status} == {"q", "r", :success}
    end

    test "an error alone marks the span ERRORED" do
      {_, [trace]} =
        capture(fn ->
          {:ok, ctx} = Tracing.open_span(:base, name: "b")
          Tracing.close_span(ctx, error: "boom")
        end)

      assert [%Span{status: :errored, error: "boom"}] = trace.root_spans
    end

    test "close_span/2 raises for a span this process did not open" do
      {_, _} =
        capture(fn ->
          {:ok, ctx} = Tracing.open_span(:base, name: "b")

          task =
            Task.async(fn ->
              assert_raise ArgumentError, ~r/not open in this process/, fn ->
                Tracing.close_span(ctx)
              end
            end)

          Task.await(task)
          Tracing.close_span(ctx)
        end)
    end

    test "record_span/2 records a finished span under the current one" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            Tracing.record_span(:llm,
              name: "streamed",
              model: "m",
              start_us: 1_000,
              end_us: 2_000,
              input: "q",
              output: "a"
            )
          end)
        end)

      [agent] = trace.root_spans

      assert [%Span{name: "streamed", start_us: 1_000, end_us: 2_000, status: :success}] =
               agent.children

      assert hd(agent.children).output == "a"
    end

    test "record_span/2 alone makes a trace of one span" do
      {_, [trace]} =
        capture(fn -> Tracing.record_span(:tool, name: "t", status: :errored, error: "x") end)

      assert trace.status == :errored
      assert [%Span{name: "t", error: "x"}] = trace.root_spans
    end
  end

  describe "trace/2" do
    test "opens a trace with attributes for the spans run inside it" do
      {result, [trace]} =
        capture(fn ->
          Tracing.trace(
            [
              name: "support",
              tags: ["beta"],
              metadata: %{"k" => 1},
              user_id: "u",
              input: "q",
              metrics: [DeepEvalEx.Metrics.ExactMatch],
              thread_id: ""
            ],
            fn ->
              Tracing.span(:agent, [name: "a"], fn ->
                Tracing.span(:tool, [name: "t"], fn -> :ok end)
              end)
            end
          )
        end)

      assert result == :ok

      assert {trace.name, trace.tags, trace.metadata, trace.user_id} ==
               {"support", ["beta"], %{"k" => 1}, "u"}

      assert trace.metrics == [DeepEvalEx.Metrics.ExactMatch]
      # Python truthiness: an empty string does not overwrite.
      assert trace.thread_id == nil
      # A set input wins over the root's.
      assert trace.input == "q"
      assert trace.output == "ok"
      assert [%Span{name: "a", children: [%Span{name: "t"}]}] = trace.root_spans
    end

    test "ends an empty trace when it returns" do
      {_, [trace]} = capture(fn -> Tracing.trace([name: "empty"], fn -> :ok end) end)
      assert %Trace{name: "empty", root_spans: [], status: :success} = trace
    end

    test "joins the live trace inside a span" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            Tracing.trace([name: "joined"], fn ->
              Tracing.span(:tool, [name: "t"], fn -> 1 end)
            end)
          end)
        end)

      assert trace.name == "joined"
      assert [%Span{children: [%Span{name: "t"}]}] = trace.root_spans
    end

    test "ends the trace when its first root span closes, as deepeval" do
      # deepeval's end_trace runs when a root span exits with no other span
      # active, so a second call inside the same trace() starts a new trace.
      {_, traces} =
        capture(fn ->
          Tracing.trace([name: "n"], fn ->
            Tracing.span(:base, [name: "first"], fn -> 1 end)
            Tracing.span(:base, [name: "second"], fn -> 2 end)
          end)
        end)

      assert [{"n", ["first"]}, {nil, ["second"]}] =
               Enum.map(traces, &{&1.name, names(&1.root_spans)})
    end

    test "keeps the llm and agent span contexts for the block only" do
      Tracing.trace([llm_span_context: [model: "m"], agent_span_context: [metrics: []]], fn ->
        assert Tracing.llm_span_context() == [model: "m"]
        assert Tracing.agent_span_context() == [metrics: []]
      end)

      assert Tracing.llm_span_context() == nil
      assert Tracing.agent_span_context() == nil
    end
  end

  describe "context across processes" do
    test "Task, Task.async_stream and Task.Supervisor children inherit through $callers" do
      supervisor = start_supervised!(Task.Supervisor)

      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            Task.await(Task.async(fn -> Tracing.span(:tool, [name: "task"], fn -> 1 end) end))

            ["s1", "s2"]
            |> Task.async_stream(fn name -> Tracing.span(:tool, [name: name], fn -> 2 end) end)
            |> Enum.to_list()

            supervisor
            |> Task.Supervisor.async_nolink(fn ->
              Tracing.span(:tool, [name: "supervised"], fn -> 3 end)
            end)
            |> Task.await()
          end)
        end)

      [agent] = trace.root_spans
      assert Enum.sort(names(agent.children)) == ["s1", "s2", "supervised", "task"]
      assert Enum.all?(agent.children, &(&1.parent_uuid == agent.uuid))
    end

    test "a child resolves its parent when its first span opens" do
      parent = self()

      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "grandparent"], fn ->
            task =
              Tracing.span(:agent, [name: "parent"], fn ->
                Task.async(fn ->
                  receive do
                    :go -> Tracing.span(:tool, [name: "late"], fn -> :ok end)
                  end
                end)
              end)

            send(task.pid, :go)
            Task.await(task)
            send(parent, :done)
          end)
        end)

      assert_received :done
      [grandparent] = trace.root_spans
      assert names(grandparent.children) == ["parent", "late"]
    end

    test "Tracing.async/1 snapshots the context and carries usage and the ledger" do
      {{_, usages}, ledger} =
        Ledger.track(fn ->
          Usage.track(fn ->
            capture(fn ->
              Tracing.span(:agent, [name: "agent"], fn ->
                task =
                  Tracing.async(fn ->
                    Usage.record(Usage.new("gpt-4o-mini", 1, 2))
                    Ledger.record_confidence(0.4)
                    Tracing.span(:tool, [name: "fetch"], fn -> :fetched end)
                  end)

                assert Tracing.await(task) == :fetched
              end)
            end)
          end)
        end)

      assert [%Usage{model: "gpt-4o-mini"}] = usages
      assert ledger.confidence == 0.4
    end

    test "Tracing.async/1 keeps the spawning span even for a process outside $callers" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            task = Tracing.async(fn -> Process.delete(:"$callers") && Tracing.context() end)
            assert %Ctx{span_uuid: uuid} = Tracing.await(task)
            assert uuid == Tracing.context().span_uuid
          end)
        end)

      assert [%Span{name: "agent"}] = trace.root_spans
    end

    test "a GenServer joins the trace through an explicit hand-off" do
      planner = start_supervised!(Planner)

      {plan, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            GenServer.call(planner, {:plan, "refund", Tracing.context()})
          end)
        end)

      assert plan == "plan for refund"
      [agent] = trace.root_spans
      assert [%Span{name: "planner", input: "refund"}] = agent.children
      assert :sys.get_state(planner) == nil
      assert :ets.lookup(Store, {:pid, planner}) == []
    end

    test "with_context/2 restores the previous context, also on a raise" do
      {_, [_trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            ctx = Tracing.context()

            assert_raise RuntimeError, fn ->
              Tracing.with_context(nil, fn ->
                assert Tracing.context() == %Ctx{}
                raise "boom"
              end)
            end

            assert Tracing.context() == ctx
          end)
        end)
    end

    test "with_context(nil, fun) runs untraced, cut off from $callers" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            Tracing.with_context(nil, fn -> Tracing.span(:tool, [name: "other"], fn -> 1 end) end)
          end)
        end)

      # "other" started a trace of its own, outside the capture.
      assert [%Span{children: []}] = trace.root_spans
    end

    test "a bare spawn without a hand-off starts its own trace" do
      ref = make_ref()
      events = :telemetry_test.attach_event_handlers(self(), [[:deep_eval_ex, :trace, :stop]])
      on_exit(fn -> :telemetry.detach(events) end)
      parent = self()

      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            spawn(fn ->
              Tracing.span(:tool, [name: "spawned"], fn -> :ok end)
              send(parent, {ref, :spawned})
            end)

            assert_receive {^ref, :spawned}
          end)
        end)

      assert [%Span{children: []}] = trace.root_spans

      assert_received {[:deep_eval_ex, :trace, :stop], ^events, _,
                       %{route: :off, trace: %Trace{root_spans: [%Span{name: "spawned"}]}}}
    end
  end

  describe "the store" do
    test "marks a dead owner's open spans ERRORED and closes their trace" do
      parent = self()

      {_, [trace]} =
        capture(fn ->
          task =
            Task.async(fn ->
              {:ok, _ctx} = Tracing.open_span(:tool, name: "stuck")
              send(parent, :opened)
              Process.sleep(:infinity)
            end)

          assert_receive :opened
          Task.shutdown(task, :brutal_kill)
        end)

      assert trace.status == :errored
      assert [%Span{name: "stuck", status: :errored, error: "killed"} = span] = trace.root_spans
      assert span.end_us != nil
    end

    test "capture/2 exports a trace still open after :await_open as IN_PROGRESS" do
      events =
        :telemetry_test.attach_event_handlers(self(), [
          [:deep_eval_ex, :trace, :timeout],
          [:deep_eval_ex, :trace, :stop]
        ])

      on_exit(fn -> :telemetry.detach(events) end)
      parent = self()

      {task, [trace]} =
        capture(
          fn ->
            task =
              Task.async(fn ->
                Tracing.span(:agent, [name: "slow"], fn ->
                  send(parent, :opened)

                  receive do
                    :finish -> :ok
                  end
                end)
              end)

            assert_receive :opened
            task
          end,
          await_open: 20
        )

      assert %Trace{status: :in_progress, end_us: nil} = trace
      assert [%Span{name: "slow", status: :in_progress, end_us: nil}] = trace.root_spans
      uuid = trace.uuid
      assert_received {[:deep_eval_ex, :trace, :timeout], ^events, _, %{trace: %{uuid: ^uuid}}}

      # Closed later, the trace goes nowhere but telemetry.
      send(task.pid, :finish)
      Task.await(task)

      assert_receive {[:deep_eval_ex, :trace, :stop], ^events, _,
                      %{route: :off, trace: %Trace{uuid: ^uuid, status: :success}}}

      assert rows(uuid) == []
    end

    test "capture/2 waits for traces still open in live processes" do
      parent = self()

      {_, [trace]} =
        capture(fn ->
          Task.start(fn ->
            Tracing.span(:agent, [name: "background"], fn ->
              send(parent, :opened)
              Process.sleep(30)
            end)
          end)

          assert_receive :opened
        end)

      assert [%Span{name: "background", status: :success}] = trace.root_spans
    end

    test "capture/2 restores the context and re-raises" do
      assert_raise RuntimeError, "boom", fn ->
        capture(fn -> Tracing.span(:base, [name: "b"], fn -> raise "boom" end) end)
      end

      assert Tracing.context() == nil
    end

    test "capture/2 captures traces apart from an enclosing span" do
      {_, [outer]} =
        capture(fn ->
          Tracing.span(:agent, [name: "outer"], fn ->
            {_, [inner]} = capture(fn -> Tracing.span(:tool, [name: "inner"], fn -> 1 end) end)
            assert [%Span{name: "inner", parent_uuid: nil}] = inner.root_spans
          end)
        end)

      assert [%Span{name: "outer", children: []}] = outer.root_spans
    end
  end

  describe "suppress/1" do
    test "records no span, in the process or its tasks" do
      {result, traces} =
        capture(fn ->
          Tracing.suppress(fn ->
            Tracing.span(:llm, [name: "judge"], fn -> :ok end)
            Task.await(Task.async(fn -> Tracing.span(:llm, [name: "t"], fn -> :ok end) end))
            Tracing.trace([name: "x"], fn -> :in_trace end)
          end)
        end)

      assert {result, traces} == {:in_trace, []}
    end

    test "keeps a metric's judge calls out of the user's trace" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            {:ok, _} = SpanningMetric.measure(TestCase.new!(input: "q", actual_output: "a"))
          end)
        end)

      assert [%Span{name: "agent", children: []}] = trace.root_spans
    end
  end

  describe "telemetry" do
    test "emits span start, stop and exception events and the trace stop" do
      events =
        :telemetry_test.attach_event_handlers(self(), [
          [:deep_eval_ex, :span, :start],
          [:deep_eval_ex, :span, :stop],
          [:deep_eval_ex, :span, :exception],
          [:deep_eval_ex, :trace, :stop]
        ])

      on_exit(fn -> :telemetry.detach(events) end)

      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            try do
              Tracing.span(:tool, [name: "t"], fn -> raise "x" end)
            rescue
              _ -> :ok
            end
          end)
        end)

      [agent] = trace.root_spans
      [tool] = agent.children
      agent_uuid = agent.uuid
      trace_uuid = trace.uuid

      assert_received {[:deep_eval_ex, :span, :start], ^events, %{system_time: _},
                       %{
                         type: :agent,
                         trace_uuid: ^trace_uuid,
                         parent_uuid: nil,
                         span: %Span{name: "a"},
                         telemetry_span_context: ctx
                       }}

      assert_received {[:deep_eval_ex, :span, :start], ^events, _,
                       %{type: :tool, parent_uuid: ^agent_uuid}}

      assert_received {[:deep_eval_ex, :span, :exception], ^events, %{duration: _},
                       %{
                         kind: :error,
                         reason: %RuntimeError{},
                         stacktrace: [_ | _],
                         span: %Span{status: :errored, error: "x"}
                       }}

      assert_received {[:deep_eval_ex, :span, :stop], ^events, %{duration: duration},
                       %{span: %Span{name: "a", status: :success}, telemetry_span_context: ^ctx}}

      assert is_integer(duration)
      refute tool.status == :success

      assert_received {[:deep_eval_ex, :trace, :stop], ^events, %{duration: _},
                       %{route: :capture, trace: %Trace{uuid: ^trace_uuid}}}
    end
  end
end
