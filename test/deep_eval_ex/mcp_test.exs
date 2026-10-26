defmodule DeepEvalEx.MCPTest do
  @moduledoc """
  The MCP types (`DeepEvalEx.MCPServer`, `DeepEvalEx.MCPToolCall`,
  `DeepEvalEx.MCPResourceCall`, `DeepEvalEx.MCPPromptCall`), the
  `DeepEvalEx.MCP` helpers, and what turns and test cases holding MCP calls
  dump to, against `test/fixtures/deepeval/mcp/dumps.json`, written by
  deepeval 4.3.1 (`scripts/parity/generate_fixtures.py mcp`).
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{Expectations, Utils}
  alias DeepEvalEx.Metrics.Utils.{Turns, Verbose}
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.SystemOne.State
  alias DeepEvalEx.Test.ParityMetrics.ConversationalStub
  alias DeepEvalEx.TestRun.JSON

  alias DeepEvalEx.{
    ConversationalTestCase,
    MCP,
    MCPPromptCall,
    MCPResourceCall,
    MCPServer,
    MCPToolCall,
    TestCase,
    Turn
  }

  alias Jason.OrderedObject

  doctest DeepEvalEx.MCP
  doctest DeepEvalEx.MCPServer
  doctest DeepEvalEx.MCPToolCall
  doctest DeepEvalEx.MCPResourceCall
  doctest DeepEvalEx.MCPPromptCall

  @dumps_path Path.expand("../fixtures/deepeval/mcp/dumps.json", __DIR__)
  @external_resource @dumps_path

  @tool_result %{"content" => [%{"type" => "text", "text" => "18°C"}], "isError" => false}
  @resource_result %{"contents" => [%{"uri" => "file:///notes.txt", "text" => "Hi"}]}
  @prompt_result %{"messages" => [%{"role" => "user", "content" => %{"type" => "text"}}]}

  @turn_params [
    :content,
    :role,
    :tools_called,
    :mcp_tools_called,
    :mcp_resources_called,
    :mcp_prompts_called,
    :scenario
  ]
  @single_params [
    :input,
    :mcp_servers,
    :mcp_tools_called,
    :mcp_resources_called,
    :mcp_prompts_called
  ]

  describe "deepeval's dumps" do
    setup do
      dumps = @dumps_path |> File.read!() |> Jason.decode!(objects: :ordered_objects)
      turns = Enum.map(dumps["turns"], &(&1 |> attrs() |> Turn.new!()))

      conversation =
        ConversationalTestCase.new!(scenario: "Weather lookup", turns: turns)

      test_case = dumps["test_case"] |> attrs() |> TestCase.new!()

      %{dumps: dumps, turns: turns, conversation: conversation, test_case: test_case}
    end

    test "a turn's repr", %{dumps: dumps, turns: turns} do
      assert Enum.map(turns, &Python.repr/1) == dumps["turn_reprs"]
    end

    test "dataset format_turns", %{dumps: dumps, turns: turns} do
      assert Utils.format_turns(turns) == dumps["format_turns"]
    end

    test "convert_turn_to_dict, as prompts print it", %{dumps: dumps, turns: turns} do
      assert Enum.map(turns, &Python.repr(Turns.convert_turn_to_dict(&1, @turn_params))) ==
               dumps["turn_dicts"]
    end

    test "a multi-turn System One state", %{dumps: dumps, conversation: conversation} do
      assert JSON.encode!(State.multi_turn(@turn_params, conversation)) ==
               JSON.encode!(dumps["multi_turn_state"])
    end

    test "a single-turn System One state", %{dumps: dumps, test_case: test_case} do
      assert JSON.encode!(State.single_turn(@single_params, test_case)) ==
               JSON.encode!(dumps["single_turn_state"])
    end

    test "expectation evidence", %{dumps: dumps, conversation: conversation, test_case: test_case} do
      assert JSON.encode!(Expectations.evidence(conversation)) ==
               JSON.encode!(dumps["conversational_evidence"])

      assert JSON.encode!(Expectations.evidence(test_case)) == JSON.encode!(dumps["evidence"])
    end

    test "a turn in verbose logs", %{dumps: dumps, turns: [_user, assistant]} do
      turn = %{assistant | mcp_resources_called: nil}

      assert Verbose.prettify_list([Turn.model_dump(turn)]) == dumps["verbose_turn"]
    end

    test "servers' repr and tool names", %{dumps: dumps, test_case: test_case} do
      assert Python.repr(test_case.mcp_servers) == dumps["servers_repr"]

      assert test_case.mcp_servers |> MCP.available_tool_names() |> Enum.sort() ==
               dumps["available_tool_names"]
    end

    test "resource URIs as AnyUrl normalises them", %{dumps: dumps} do
      for {uri, normalised} <- dumps["uris"].values do
        assert MCPResourceCall.new!(uri: uri, result: @resource_result).uri == normalised,
               "for #{uri}"
      end
    end
  end

  describe "MCPServer.new/1" do
    test "takes atom or string keys and deepeval's transport names" do
      for transport <- ["stdio", "sse", "streamable-http"] do
        assert {:ok, %MCPServer{transport: atom}} =
                 MCPServer.new(%{"server_name" => "s", "transport" => transport})

        assert MCPServer.transport_name(atom) == transport
      end

      assert {:ok, %MCPServer{server_name: "s", transport: :sse, available_tools: [%{name: "x"}]}} =
               MCPServer.new(server_name: "s", transport: :sse, available_tools: [%{name: "x"}])
    end

    test "rejects what deepeval's validate_mcp_servers rejects" do
      assert MCPServer.new(server_name: "s", available_tools: %{"name" => "x"}) ==
               {:error, "'available_tools' must be a list"}

      assert MCPServer.new(server_name: "s", available_prompts: ["x"]) ==
               {:error, "'available_prompts' must be a list of dicts"}

      assert {:error, "'server_name' must be a string" <> _} = MCPServer.new(%{})

      assert {:error, "'transport' must be" <> _} =
               MCPServer.new(server_name: "s", transport: "ws")

      assert_raise ArgumentError, ~r/Invalid MCP server/, fn -> MCPServer.new!(:nope) end
    end
  end

  describe "the MCP calls' new/1" do
    test "build calls from attributes, keeping the result as given" do
      result = OrderedObject.new([{"isError", false}, {"content", []}])

      assert {:ok, %MCPToolCall{name: "t", args: %{"a" => 1}, result: ^result}} =
               MCPToolCall.new(%{"name" => "t", "args" => %{"a" => 1}, "result" => result})

      assert {:ok, %MCPPromptCall{name: "p", result: %{messages: []}}} =
               MCPPromptCall.new(name: "p", result: %{messages: []}, extra: 1)

      assert {:ok, %MCPResourceCall{uri: "file:///notes.txt"}} =
               MCPResourceCall.new(uri: "file:///notes.txt", result: @resource_result)
    end

    test "require a spec-shaped result" do
      assert {:error, "'result' must be a CallToolResult" <> _} =
               MCPToolCall.new(name: "t", args: %{}, result: %{"contents" => []})

      assert {:error, "'result' must be a ReadResourceResult" <> _} =
               MCPResourceCall.new(uri: "file:///x", result: @tool_result)

      assert {:error, "'result' must be a GetPromptResult" <> _} =
               MCPPromptCall.new(name: "p", result: "Hi")
    end

    test "check the name, args and URI" do
      assert {:error, "'name' must be a string" <> _} =
               MCPToolCall.new(args: %{}, result: @tool_result)

      assert {:error, "'args' must be a map" <> _} =
               MCPToolCall.new(name: "t", args: [1], result: @tool_result)

      for uri <- ["notaurl", "", "/rel/path", "http://", "https://a b/", nil] do
        assert {:error, "'uri' must be an absolute URI" <> _} =
                 MCPResourceCall.new(uri: uri, result: @resource_result)
      end

      assert_raise ArgumentError, ~r/Invalid MCP prompt call/, fn -> MCPPromptCall.new!([1]) end
    end
  end

  describe "test case and turn fields" do
    test "TestCase.new/1 builds MCP structs from attributes" do
      test_case =
        TestCase.new!(
          input: "Q",
          mcp_servers: [%{"server_name" => "weather"}],
          mcp_tools_called: [%{name: "t", args: %{}, result: @tool_result}],
          mcp_resources_called: [MCPResourceCall.new!(uri: "file:///n", result: @resource_result)],
          mcp_prompts_called: [[name: "p", result: @prompt_result]]
        )

      assert [%MCPServer{server_name: "weather"}] = test_case.mcp_servers
      assert [%MCPToolCall{name: "t"}] = test_case.mcp_tools_called
      assert [%MCPResourceCall{uri: "file:///n"}] = test_case.mcp_resources_called
      assert [%MCPPromptCall{name: "p"}] = test_case.mcp_prompts_called
    end

    test "invalid MCP fields are errors" do
      assert {:error, _} = TestCase.new(input: "Q", mcp_servers: [%{"transport" => "stdio"}])
      assert {:error, _} = TestCase.new(input: "Q", mcp_tools_called: [%{name: "t"}])
      assert {:error, _} = Turn.new(role: :user, content: "Hi", mcp_prompts_called: ["p"])

      assert {:error, _} =
               ConversationalTestCase.new(
                 turns: [%{role: :user, content: "Hi"}],
                 mcp_servers: "weather"
               )
    end

    test "a turn's model_dump writes its MCP calls" do
      turn =
        Turn.new!(
          role: :assistant,
          content: "18°C",
          mcp_tools_called: [%{name: "t", args: %{}, result: @tool_result}]
        )

      dump = Turn.model_dump(turn)

      assert dump["mcp_tools_called"] == [
               OrderedObject.new([{"name", "t"}, {"args", %{}}, {"result", @tool_result}])
             ]

      assert dump["mcp_resources_called"] == nil
    end
  end

  describe "classify_tool_call_types/2" do
    test "marks only the named tool calls, and keeps nil" do
      names = MapSet.new(["add"])

      assert [%ToolCall{type: :mcp}, %ToolCall{type: :function}] =
               MCP.classify_tool_call_types([%ToolCall{name: "add"}, %ToolCall{name: "x"}], names)

      assert MCP.classify_tool_call_types(nil, names) == nil
    end
  end

  describe "process_servers/2" do
    setup do
      calc = %{server_name: "calc", available_tools: [%{"name" => "add"}]}
      %{calc: calc, test_case: TestCase.new!(input: "Q", tools_called: [%{name: "add"}])}
    end

    test "gives a test case without servers the run's", %{calc: calc, test_case: test_case} do
      [processed] = MCP.process_servers([test_case], [calc])

      assert [%MCPServer{server_name: "calc"}] = processed.mcp_servers
      assert [%ToolCall{type: :mcp}] = processed.tools_called
    end

    test "prefers a test case's own servers", %{calc: calc, test_case: test_case} do
      own = %{test_case | mcp_servers: [MCPServer.new!(server_name: "empty")]}

      assert MCP.process_servers([own], [calc]) == [own]
    end

    test "leaves test cases alone without servers", %{test_case: test_case} do
      assert MCP.process_servers([test_case]) == [test_case]

      assert MCP.process_servers([%{test_case | mcp_servers: []}], []) == [
               %{test_case | mcp_servers: []}
             ]
    end

    test "marks a conversation's turns", %{calc: calc} do
      conversation =
        ConversationalTestCase.new!(
          mcp_servers: [calc],
          turns: [%{role: :assistant, content: "5", tools_called: [%{name: "add"}]}]
        )

      [processed] = MCP.process_servers([conversation])

      assert [%Turn{tools_called: [%ToolCall{type: :mcp}]}] = processed.turns
    end

    test "raises for invalid servers", %{test_case: test_case} do
      assert_raise ArgumentError, ~r/'server_name' must be a string/, fn ->
        MCP.process_servers([test_case], [%{transport: "stdio"}])
      end
    end
  end

  describe "DeepEvalEx.evaluate/3" do
    test "returns test results with the MCP tool calls marked" do
      test_case =
        ConversationalTestCase.new!(
          turns: [%{role: :assistant, content: "5", tools_called: [%{name: "add"}]}]
        )

      metric = %ConversationalStub{
        name: "Stub",
        score: 1.0,
        threshold: 0.5,
        reason: "Fixed",
        evaluation_model: "stub",
        evaluation_cost: 0.0,
        input_tokens: 1,
        output_tokens: 1
      }

      {:ok, evaluation} =
        DeepEvalEx.evaluate([test_case], [metric],
          mcp_servers: [[server_name: "calc", available_tools: [%{name: "add"}]]]
        )

      [%{turns: [turn]}] = evaluation.test_results
      assert [%{type: :mcp}] = turn.tools_called
    end
  end

  # A turn's or test case's attributes from the fixture: MCP calls and
  # servers, and tool calls, as maps; the values inside them stay ordered.
  defp attrs(%OrderedObject{values: pairs}) do
    Map.new(pairs, fn
      {key, items}
      when key in ~w(tools_called mcp_tools_called mcp_resources_called mcp_prompts_called mcp_servers) ->
        {key, Enum.map(items, &Map.new(&1.values))}

      pair ->
        pair
    end)
  end
end
