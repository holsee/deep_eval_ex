defmodule DeepEvalEx.Tracing.CompactTraceTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict, Span}
  alias Jason.OrderedObject

  doctest CompactTrace

  defp keys(%OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  describe "compact/1" do
    test "keeps the whitelisted keys in _TRACE_SPAN_KEYS order" do
      dict =
        OrderedObject.new([
          {"output", "out"},
          {"agent_handoffs", ["billing"]},
          {"model", "gpt"},
          {"input_token_count", 3.0},
          {"name", "n"},
          {"provider", "openai"},
          {"description", "d"},
          {"type", "llm"},
          {"prompt_alias", "p"},
          {"children", []}
        ])

      assert keys(CompactTrace.compact(dict)) ==
               ~w(name type description output model agent_handoffs)
    end

    test "drops nil, [] and \"\" but keeps other falsy values" do
      dict =
        OrderedObject.new([
          {"name", ""},
          {"input", OrderedObject.new([])},
          {"output", 0},
          {"error", nil},
          {"context", []},
          {"expected_output", false},
          {"children", []}
        ])

      assert CompactTrace.compact(dict) ==
               OrderedObject.new([
                 {"input", OrderedObject.new([])},
                 {"output", 0},
                 {"expected_output", false}
               ])
    end

    test "nests the compacted children and leaves out an empty list" do
      child = OrderedObject.new([{"name", "c"}, {"children", []}])
      dict = OrderedObject.new([{"name", "p"}, {"children", [child]}])

      assert CompactTrace.compact(dict) ==
               OrderedObject.new([
                 {"name", "p"},
                 {"children", [OrderedObject.new([{"name", "c"}])]}
               ])
    end

    test "makes values jsonable as deepeval's _jsonable: str() of anything else" do
      tool_call = %ToolCall{
        name: "search",
        type: :mcp,
        description: "it's",
        output: [1, 0.5, nil],
        input_parameters: OrderedObject.new([{"b", 1}, {"a", true}])
      }

      dict =
        OrderedObject.new([
          {"input", %{1 => {:ok, :atom}}},
          {"output", %RetrievedContextData{context: "c", source: "s"}},
          {"tools_called", [tool_call]},
          {"expected_output", ~D[2026-10-23]}
        ])

      compact = CompactTrace.compact(dict)

      assert compact["input"] == OrderedObject.new([{"1", ["ok", "atom"]}])
      assert compact["output"] == "context='c' source='s'"
      assert compact["expected_output"] == "2026-10-23"

      assert compact["tools_called"] == [
               ~S|name='search' type=<ToolCallType.MCP: 'MCP'> description="it's" | <>
                 ~S|reasoning=None output=[1, 0.5, None] input_parameters={'b': 1, 'a': True}|
             ]
    end

    test "returns what is not a dict as it is" do
      assert CompactTrace.compact(nil) == nil
      assert CompactTrace.compact("trace") == "trace"
    end

    test "compacts a nested trace dict" do
      tool =
        Span.new!(uuid: "t", name: "search", type: :tool, input: %{"q" => "x"}, output: "hit")

      root =
        Span.new!(
          uuid: "r",
          name: "agent",
          type: :agent,
          available_tools: ["search"],
          tools_called: [%ToolCall{name: "search"}],
          children: [tool]
        )

      assert root |> NestedDict.build() |> CompactTrace.compact() ==
               OrderedObject.new([
                 {"name", "agent"},
                 {"type", "agent"},
                 {"tools_called",
                  [
                    "name='search' type=<ToolCallType.FUNCTION: 'FUNCTION'> description=None " <>
                      "reasoning=None output=None input_parameters=None"
                  ]},
                 {"available_tools", ["search"]},
                 {"children",
                  [
                    OrderedObject.new([
                      {"name", "search"},
                      {"type", "tool"},
                      {"input", OrderedObject.new([{"q", "x"}])},
                      {"output", "hit"}
                    ])
                  ]}
               ])
    end
  end
end
