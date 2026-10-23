defmodule DeepEvalEx.Tracing.TreeTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.{Span, Trace, Tree}
  alias Jason.OrderedObject

  defp span(uuid, parent, seq, attrs \\ []) do
    Span.new!(
      [uuid: uuid, trace_uuid: "t", parent_uuid: parent, seq: seq, name: uuid, status: :success] ++
        attrs
    )
  end

  defp names(spans), do: Enum.map(spans, & &1.name)

  describe "build/3" do
    test "nests children under their parents in start order, whatever the row order" do
      spans = [
        span("c2", "root", 4),
        span("root", nil, 1),
        span("gc", "c1", 3),
        span("c1", "root", 2)
      ]

      %Trace{root_spans: [root]} = Tree.build(%Trace{uuid: "t"}, spans)

      assert root.name == "root"
      assert names(root.children) == ["c1", "c2"]
      assert names(hd(root.children).children) == ["gc"]
    end

    test "keeps several roots in start order" do
      trace = Tree.build(%Trace{}, [span("b", nil, 2), span("a", nil, 1)])
      assert names(trace.root_spans) == ["a", "b"]
    end

    test "makes a span whose parent is missing a root, keeping its parent uuid" do
      trace = Tree.build(%Trace{}, [span("root", nil, 1), span("orphan", "gone", 2)])

      assert names(trace.root_spans) == ["root", "orphan"]
      assert Enum.at(trace.root_spans, 1).parent_uuid == "gone"
    end

    test "fills tools_called from tool children, as Observer.__exit__" do
      spans = [
        span("agent", nil, 1, type: :agent),
        span("search", "agent", 2,
          type: :tool,
          description: "Searches",
          input: OrderedObject.new([{"q", "x"}]),
          output: %{"hits" => 2}
        ),
        span("plain", "agent", 3, input: %{"a" => 1}),
        span("echo", "agent", 4, type: :tool, input: "raw", output: "raw")
      ]

      %Trace{root_spans: [agent]} = Tree.build(%Trace{}, spans)

      assert agent.tools_called == [
               %ToolCall{
                 name: "search",
                 description: "Searches",
                 input_parameters: OrderedObject.new([{"q", "x"}]),
                 output: %{"hits" => 2}
               },
               # prepare_tool_call_input_parameters wraps a value that is not a dict
               %ToolCall{name: "echo", input_parameters: %{"output" => "raw"}, output: "raw"}
             ]
    end

    test "keeps falsy tool inputs as they are and leaves set tools_called alone" do
      set = [%ToolCall{name: "given"}]

      spans = [
        span("a", nil, 1, type: :agent),
        span("t1", "a", 2, type: :tool, input: ""),
        span("b", nil, 3, type: :agent, tools_called: set),
        span("t2", "b", 4, type: :tool)
      ]

      %Trace{root_spans: [a, b]} = Tree.build(%Trace{}, spans)

      assert [%ToolCall{name: "t1", input_parameters: ""}] = a.tools_called
      assert b.tools_called == set
    end

    test "leaves tools_called unset without tool children" do
      %Trace{root_spans: [root]} = Tree.build(%Trace{}, [span("r", nil, 1), span("c", "r", 2)])
      assert root.tools_called == nil
    end

    test "marks the trace ERRORED when a root span errored" do
      errored = span("r", nil, 1, status: :errored, error: "boom")
      assert Tree.build(%Trace{status: :success}, [errored]).status == :errored

      child_errored = [span("r", nil, 1), span("c", "r", 2, status: :errored)]
      assert Tree.build(%Trace{status: :success}, child_errored).status == :success

      orphan_errored = [span("o", "gone", 1, status: :errored)]
      assert Tree.build(%Trace{status: :success}, orphan_errored).status == :success
    end

    test "keeps the trace's own fields" do
      trace = Tree.build(%Trace{uuid: "t", name: "support", input: "q"}, [span("r", nil, 1)])
      assert {trace.uuid, trace.name, trace.input} == {"t", "support", "q"}
    end

    test "under mode: :sync keeps only the first root's first child, as end_trace" do
      spans = [
        span("wrapper", nil, 1),
        span("first", "wrapper", 2),
        span("leaf", "first", 3),
        span("second", "wrapper", 4)
      ]

      %Trace{root_spans: [first]} = Tree.build(%Trace{}, spans, mode: :sync)

      assert first.name == "first"
      assert first.parent_uuid == nil
      assert names(first.children) == ["leaf"]
    end

    test "under mode: :sync clears root parents when there is nothing to strip" do
      trace = Tree.build(%Trace{}, [span("o", "gone", 1)], mode: :sync)
      assert [%Span{name: "o", parent_uuid: nil}] = trace.root_spans
    end

    test "takes the status from the roots before the sync strip" do
      spans = [span("wrapper", nil, 1, status: :errored), span("user", "wrapper", 2)]
      assert Tree.build(%Trace{status: :success}, spans, mode: :sync).status == :errored
    end

    test "builds an empty trace" do
      assert %Trace{root_spans: []} = Tree.build(%Trace{}, [])
    end
  end
end
