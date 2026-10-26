defmodule DeepEvalEx.Tracing.NestedDictTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{NestedDict, Span}
  alias Jason.OrderedObject

  doctest NestedDict

  # 2023-11-14T22:13:20.999999Z
  @t0 1_700_000_000_999_999

  defp span(uuid, attrs) do
    Span.new!(
      [uuid: uuid, trace_uuid: "t", name: uuid, status: :success, start_us: @t0, end_us: @t0] ++
        attrs
    )
  end

  defp keys(%OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  describe "build/1" do
    test "pops the ids, times, status, test case, metrics and metadata" do
      root =
        span("root",
          type: :agent,
          parent_uuid: "outer",
          status: :errored,
          error: "boom",
          metadata: %{"a" => 1},
          metric_collection: "collection",
          metrics: [ExactMatch],
          llm_test_case: TestCase.new!(input: "q"),
          input: OrderedObject.new([{"q", "hi"}]),
          output: "out",
          integration: "jido"
        )

      dict = NestedDict.build(root)

      assert keys(dict) ==
               ~w(name type input output error integration available_tools agent_handoffs children)

      assert dict["type"] == "agent"
      assert dict["available_tools"] == []
      assert dict["children"] == []
    end

    test "keeps falsy values that are not nil, as `is not None`" do
      dict = NestedDict.build(span("s", input: OrderedObject.new([]), output: "", context: []))

      assert dict["input"] == OrderedObject.new([])
      assert dict["output"] == ""
      assert dict["context"] == []
    end

    test "flattens the retrieval context, and leaves an empty one out" do
      retriever =
        span("r",
          type: :retriever,
          retrieval_context: ["a", "b"],
          embedder: "e",
          top_k: 2,
          chunk_size: 10
        )

      dict = NestedDict.build(retriever)

      assert keys(dict) == ~w(name type retrieval_context embedder top_k chunk_size children)
      assert dict["retrieval_context"] == ["a", "b"]
      refute "retrieval_context" in keys(NestedDict.build(span("r", retrieval_context: [])))
    end

    test "keeps tool calls as structs and the type's own fields in pydantic order" do
      tool_call = %ToolCall{name: "search", output: "hit"}

      llm =
        span("llm",
          type: :llm,
          tools_called: [tool_call],
          model: "gpt",
          provider: "openai",
          input_token_count: 3,
          cost_per_output_token: 0.5,
          prompt_alias: "own",
          prompt: %{alias: "prompt", version: "1", label: "prod", hash: "h"},
          token_intervals: %{@t0 => "Hi"}
        )

      dict = NestedDict.build(llm)

      assert keys(dict) ==
               ~w(name type tools_called model provider input_token_count cost_per_output_token
                  token_intervals prompt_alias prompt_version prompt_label prompt_commit_hash
                  children)

      assert dict["tools_called"] == [tool_call]
      # The provider is kept raw, as create_nested_spans_dict does not normalise it.
      assert dict["provider"] == "openai"
      assert dict["prompt_alias"] == "own"
      assert dict["prompt_version"] == "1"
      assert dict["token_intervals"] == OrderedObject.new([{"2023-11-14T22:13:20.999999Z", "Hi"}])
    end

    test "nests the children, a dropped span included" do
      leaf = span("leaf", type: :tool, description: "d", parent_uuid: "dropped")
      dropped = span("dropped", parent_uuid: "root", drop: true, children: [leaf])
      root = span("root", children: [dropped])

      assert %OrderedObject{} = dict = NestedDict.build(root)
      assert [%OrderedObject{} = child] = dict["children"]
      assert child["name"] == "dropped"
      assert [%OrderedObject{} = grandchild] = child["children"]
      assert keys(grandchild) == ~w(name type description children)
    end
  end

  describe "to_json/2" do
    test "renders like serialize_to_json(indent=2), tool calls with every field" do
      root =
        span("root",
          type: :agent,
          input: OrderedObject.new([{"zeta", 1}, {"alpha", :atom}]),
          output: {1, 2.0},
          tools_called: [%ToolCall{name: "search", input_parameters: %{"q" => "é"}}]
        )

      assert NestedDict.to_json(NestedDict.build(root)) == """
             {
               "name": "root",
               "type": "agent",
               "input": {
                 "zeta": 1,
                 "alpha": "atom"
               },
               "output": [
                 1,
                 2.0
               ],
               "tools_called": [
                 {
                   "name": "search",
                   "type": "FUNCTION",
                   "description": null,
                   "reasoning": null,
                   "output": null,
                   "input_parameters": {
                     "q": "\\u00e9"
                   }
                 }
               ],
               "available_tools": [],
               "agent_handoffs": [],
               "children": []
             }\
             """
    end

    test "takes json.dumps options" do
      dict = NestedDict.build(span("s", output: "é"))

      assert NestedDict.to_json(dict, indent: nil, ensure_ascii: false) ==
               ~s({"name": "s", "type": "base", "output": "é", "children": []})
    end
  end
end
