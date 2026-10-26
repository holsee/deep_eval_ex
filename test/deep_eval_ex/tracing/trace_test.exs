defmodule DeepEvalEx.Tracing.TraceTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.{Span, Trace}

  doctest DeepEvalEx.Tracing.Trace

  describe "new/1" do
    test "builds a trace with deepeval's defaults" do
      assert {:ok, trace} = Trace.new(uuid: "t1", start_us: 1_700_000_000_000_000)

      assert %Trace{
               uuid: "t1",
               status: :in_progress,
               root_spans: [],
               start_us: 1_700_000_000_000_000,
               end_us: nil,
               metrics: [],
               drop: false
             } = trace
    end

    test "takes every Trace field" do
      root = Span.new!(type: :agent, name: "support")

      assert {:ok, trace} =
               Trace.new(
                 uuid: "t1",
                 status: :success,
                 root_spans: [root],
                 start_us: 1,
                 end_us: 2,
                 name: "support-run",
                 tags: ["beta"],
                 metadata: %{"env" => "test"},
                 thread_id: "th",
                 user_id: "u",
                 input: %{"query" => "hi"},
                 output: "hello",
                 metrics: [{ExactMatch, threshold: 1.0}],
                 metric_collection: "agents",
                 test_case_id: "tc",
                 test_run_id: "tr",
                 turn_id: "turn",
                 retrieval_context: ["doc"],
                 context: ["ctx"],
                 expected_output: "hello",
                 tools_called: [%{name: "search"}],
                 expected_tools: [%ToolCall{name: "search"}],
                 drop: true
               )

      assert %Trace{root_spans: [^root], tags: ["beta"], drop: true} = trace
      assert [%ToolCall{name: "search"}] = trace.tools_called
      assert [%ToolCall{name: "search"}] = trace.expected_tools
    end

    test "validates the field types" do
      assert {:error, [%Peri.Error{key: :status}]} = Trace.new(status: "SUCCESS")
      assert {:error, [%Peri.Error{key: :root_spans}]} = Trace.new(root_spans: [%{}])
      assert {:error, [%Peri.Error{key: :tags}]} = Trace.new(tags: "beta")
      assert {:error, [%Peri.Error{key: :metrics}]} = Trace.new(metrics: [1])
    end
  end

  test "new!/1 raises on invalid attributes" do
    assert_raise ArgumentError, ~r/Invalid trace/, fn -> Trace.new!(status: :done) end
  end
end
