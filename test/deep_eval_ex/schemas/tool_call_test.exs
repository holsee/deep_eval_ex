defmodule DeepEvalEx.Schemas.ToolCallTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.ToolCall

  doctest DeepEvalEx.Schemas.ToolCall

  describe "struct defaults" do
    test "type defaults to :function" do
      assert %ToolCall{name: "search"}.type == :function
    end
  end

  describe "new/1" do
    test "defaults type to :function" do
      assert {:ok, %ToolCall{name: "search", type: :function}} = ToolCall.new(name: "search")
    end

    test "accepts :mcp type" do
      assert {:ok, %ToolCall{type: :mcp}} = ToolCall.new(name: "search", type: :mcp)
    end

    test "accepts deepeval's string type values in any case" do
      assert {:ok, %ToolCall{type: :mcp}} = ToolCall.new(%{"name" => "s", "type" => "MCP"})

      assert {:ok, %ToolCall{type: :function}} =
               ToolCall.new(%{"name" => "s", "type" => "FUNCTION"})

      assert {:ok, %ToolCall{type: :mcp}} = ToolCall.new(%{"name" => "s", "type" => "mcp"})
    end

    test "rejects an unknown type" do
      assert {:error, _} = ToolCall.new(name: "search", type: :webhook)
      assert {:error, _} = ToolCall.new(%{"name" => "search", "type" => "WEBHOOK"})
    end

    test "accepts any JSON term as output" do
      for output <- ["text", 42, 1.5, true, nil, ["a", 1], %{"temp" => 18, "unit" => "C"}] do
        assert {:ok, %ToolCall{output: ^output}} = ToolCall.new(name: "weather", output: output)
      end
    end

    test "keeps input_parameters a map" do
      assert {:ok, %ToolCall{input_parameters: %{"q" => "paris"}}} =
               ToolCall.new(name: "search", input_parameters: %{"q" => "paris"})

      assert {:error, _} = ToolCall.new(name: "search", input_parameters: ["q"])
    end

    test "accepts string keys and the camelCase inputParameters alias" do
      assert {:ok, tool} =
               ToolCall.new(%{
                 "name" => "search",
                 "description" => "Web search",
                 "reasoning" => "Needs fresh data",
                 "inputParameters" => %{"q" => "paris"},
                 "output" => %{"hits" => 3}
               })

      assert tool.name == "search"
      assert tool.description == "Web search"
      assert tool.reasoning == "Needs fresh data"
      assert tool.input_parameters == %{"q" => "paris"}
      assert tool.output == %{"hits" => 3}
    end

    test "requires a name" do
      assert {:error, _} = ToolCall.new(%{"type" => "MCP"})
    end
  end

  describe "equal?/2" do
    test "compares name, input_parameters and output only, as deepeval's ToolCall.__eq__" do
      called = %ToolCall{
        name: "search",
        type: :function,
        description: "Search the web",
        reasoning: "Needs fresh data",
        input_parameters: %{"q" => "paris"},
        output: %{"hits" => 3}
      }

      expected = %ToolCall{
        name: "search",
        type: :mcp,
        input_parameters: %{"q" => "paris"},
        output: %{"hits" => 3}
      }

      assert ToolCall.equal?(called, expected)
    end

    test "is false when the name, input_parameters or output differ" do
      tool = %ToolCall{name: "search", input_parameters: %{"q" => "paris"}, output: "ok"}

      refute ToolCall.equal?(tool, %{tool | name: "lookup"})
      refute ToolCall.equal?(tool, %{tool | input_parameters: %{"q" => "rome"}})
      refute ToolCall.equal?(tool, %{tool | output: "error"})
    end

    test "does not treat nil input_parameters as an empty map" do
      refute ToolCall.equal?(%ToolCall{name: "s"}, %ToolCall{name: "s", input_parameters: %{}})
    end
  end

  describe "json_schema/0" do
    test "describes type as an enum and output as any JSON value" do
      schema = ToolCall.json_schema()

      assert schema["properties"]["type"] == %{"type" => "string", "enum" => ["function", "mcp"]}
      assert schema["properties"]["output"] == %{}
      assert "type" in schema["required"]
    end
  end
end
