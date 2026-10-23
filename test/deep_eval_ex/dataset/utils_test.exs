defmodule DeepEvalEx.Dataset.UtilsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{Persona, Utils}
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.Turn

  doctest DeepEvalEx.Dataset.Utils

  @data %RetrievedContextData{source: "policy.md", context: "Refunds: 30 days"}

  test "delimiters are deepeval's" do
    assert Utils.delimiter() == "|"
    assert Utils.tools_delimiter() == ";"
  end

  describe "serialize_retrieval_context/1" do
    test "writes RetrievedContextData as deepeval's marker, leaving strings" do
      assert Utils.serialize_retrieval_context(["plain", @data]) ==
               ["plain", "deepeval_source=policy.md,deepeval_context=Refunds: 30 days"]
    end

    test "keeps nil" do
      assert Utils.serialize_retrieval_context(nil) == nil
    end
  end

  describe "join_retrieval_context/2 and join_context/2" do
    test "join serialised items on the delimiter" do
      assert Utils.join_retrieval_context(["a", @data]) ==
               "a|deepeval_source=policy.md,deepeval_context=Refunds: 30 days"

      assert Utils.join_retrieval_context(["a", "b"], ";") == "a;b"
      assert Utils.join_context(["a", "b"]) == "a|b"
      assert Utils.join_context(["a", "b"], ";") == "a;b"
      assert Utils.join_context([]) == ""
    end

    test "keep nil" do
      assert Utils.join_retrieval_context(nil) == nil
      assert Utils.join_context(nil) == nil
    end
  end

  describe "reconstruct_retrieval_context/1" do
    test "rebuilds RetrievedContextData from markers, leaving other strings" do
      assert Utils.reconstruct_retrieval_context([
               "plain",
               "deepeval_source=policy.md,deepeval_context=Refunds: 30 days"
             ]) == ["plain", @data]
    end

    test "inverts serialize_retrieval_context/1" do
      items = ["x", @data, %RetrievedContextData{source: "", context: ""}]

      assert items |> Utils.serialize_retrieval_context() |> Utils.reconstruct_retrieval_context() ==
               items
    end

    test "splits at the first ',deepeval_context=' and needs the marker at the start" do
      assert Utils.reconstruct_retrieval_context([
               "deepeval_source=a,b,deepeval_context=c,deepeval_context=d",
               " deepeval_source=a,deepeval_context=b"
             ]) == [
               %RetrievedContextData{source: "a,b", context: "c,deepeval_context=d"},
               " deepeval_source=a,deepeval_context=b"
             ]
    end

    test "drops a newline ending the context, as Python's $" do
      assert Utils.reconstruct_retrieval_context(["deepeval_source=a,deepeval_context=b\n"]) ==
               [%RetrievedContextData{source: "a", context: "b"}]
    end

    test "does not match across lines, as Python's re" do
      assert Utils.reconstruct_retrieval_context(["deepeval_source=a\n,deepeval_context=b"]) ==
               ["deepeval_source=a\n,deepeval_context=b"]
    end

    test "keeps nil and items that are not strings" do
      assert Utils.reconstruct_retrieval_context(nil) == nil
      assert Utils.reconstruct_retrieval_context([@data]) == [@data]
    end
  end

  describe "trim_and_load_json/1" do
    test "decodes JSON with surrounding whitespace" do
      assert Utils.trim_and_load_json("  {\"a\": [1, 2.5, null, true]}\n") ==
               {:ok, %{"a" => [1, 2.5, nil, true]}}
    end

    test "drops trailing commas when the JSON does not decode as it is" do
      assert Utils.trim_and_load_json(~s([{"name": "t", "x": {"q": 1},},])) ==
               {:ok, [%{"name" => "t", "x" => %{"q" => 1}}]}
    end

    test "leaves ', ]' inside valid JSON strings alone" do
      assert Utils.trim_and_load_json(~s(["a, ]"])) == {:ok, ["a, ]"]}
    end

    test "returns deepeval's error message otherwise" do
      assert {:error, "Invalid JSON: {nope. Error: " <> _} = Utils.trim_and_load_json("{nope")
    end
  end

  describe "parse_turns/1" do
    test "parses a JSON string or a list of maps, rebuilding retrieval context markers" do
      json =
        ~s([{"role": "user", "content": "hi", "retrieval_context": ) <>
          ~s(["deepeval_source=policy.md,deepeval_context=Refunds: 30 days", "x"], ) <>
          ~s("tools_called": [{"name": "t", "inputParameters": {"q": 1}}]}, ) <>
          ~s({"role": "assistant", "content": "é", "metadata": {}}])

      assert {:ok, [user, assistant]} = Utils.parse_turns(json)

      assert %Turn{
               role: :user,
               content: "hi",
               retrieval_context: [@data, "x"],
               tools_called: [%ToolCall{name: "t", input_parameters: %{"q" => 1}}]
             } = user

      assert %Turn{role: :assistant, content: "é", metadata: %{}} = assistant

      assert Utils.parse_turns([%{role: "user", content: "hi"}]) ==
               {:ok, [Turn.new!(role: :user, content: "hi")]}
    end

    test "returns deepeval's errors" do
      assert {:error, "Invalid JSON: " <> _} = Utils.parse_turns("nope")
      assert Utils.parse_turns(3) == {:error, "Expected a JSON string or a list of turns."}
      assert Utils.parse_turns(~s({"a": 1})) == {:error, "Expected a list of turns."}
      assert Utils.parse_turns([1]) == {:error, "Turn at index 0 is not a dictionary."}

      assert Utils.parse_turns([%{"role" => "user", "content" => "a"}, %{"content" => "b"}]) ==
               {:error, "Turn at index 1 is missing a valid 'role'."}

      assert Utils.parse_turns([%{"role" => "user"}]) ==
               {:error, "Turn at index 0 is missing a valid 'content'."}

      assert {:error, "Turn at index 0 is invalid: " <> _} =
               Utils.parse_turns([%{"role" => "bot", "content" => "c"}])
    end

    test "parse_turns!/1 raises ArgumentError" do
      assert_raise ArgumentError, "Expected a list of turns.", fn -> Utils.parse_turns!("{}") end
    end
  end

  describe "format_turns/1" do
    test "writes deepeval's JSON, the inverse of parse_turns/1" do
      turns = [
        Turn.new!(
          role: :user,
          content: "hi",
          user_id: "u1",
          retrieval_context: [@data, "x"],
          tools_called: [%{name: "t", input_parameters: %{"q" => 1}}],
          metadata: %{}
        ),
        Turn.new!(role: :assistant, content: "é", tools_called: [])
      ]

      # deepeval 4.3.1's format_turns over the same turns
      expected =
        ~s([{"role": "user", "content": "hi", "user_id": "u1", "retrieval_context": ) <>
          ~s(["deepeval_source=policy.md,deepeval_context=Refunds: 30 days", "x"], ) <>
          ~s("tools_called": [{"name": "t", "type": "FUNCTION", "inputParameters": {"q": 1}}], ) <>
          ~s("mcp_tools_called": null, "mcp_resources_called": null, "mcp_prompts_called": null, ) <>
          ~s("metadata": null}, ) <>
          ~s({"role": "assistant", "content": "é", "user_id": null, "retrieval_context": null, ) <>
          ~s("tools_called": null, "mcp_tools_called": null, "mcp_resources_called": null, ) <>
          ~s("mcp_prompts_called": null, "metadata": null}])

      assert Utils.format_turns(turns) == expected
      assert {:ok, [%Turn{retrieval_context: [@data, "x"]}, _]} = Utils.parse_turns(expected)
    end
  end

  describe "serialize_persona/1" do
    test "dumps the persona without its defaults" do
      assert Utils.serialize_persona(nil) == nil

      assert Utils.serialize_persona(%Persona{characteristics: "Calm"}) ==
               Jason.OrderedObject.new([{"characteristics", "Calm"}])

      assert Utils.serialize_persona(%Persona{
               name: "",
               characteristics: "c",
               metadata: %{"a" => 1}
             }) ==
               Jason.OrderedObject.new([
                 {"name", ""},
                 {"characteristics", "c"},
                 {"metadata", %{"a" => 1}}
               ])
    end
  end
end
