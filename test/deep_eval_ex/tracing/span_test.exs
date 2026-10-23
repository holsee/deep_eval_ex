defmodule DeepEvalEx.Tracing.SpanTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.{ExactMatch, PatternMatch}
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.Span

  doctest DeepEvalEx.Tracing.Span

  describe "new/1" do
    test "builds a base span with deepeval's defaults" do
      assert {:ok, span} = Span.new(uuid: "s1", trace_uuid: "t1", name: "step")

      assert %Span{
               type: :base,
               status: :in_progress,
               uuid: "s1",
               trace_uuid: "t1",
               parent_uuid: nil,
               name: "step",
               input: nil,
               output: nil,
               metrics: [],
               children: [],
               drop: false,
               available_tools: [],
               agent_handoffs: []
             } = span
    end

    test "keeps any term as input and output" do
      input = Jason.OrderedObject.new([{"query", "q"}, {"k", 2}])

      assert {:ok, %Span{input: ^input, output: {:ok, [1]}}} =
               Span.new(input: input, output: {:ok, [1]})
    end

    test "requires a name on agent and tool spans, as AgentSpan and ToolSpan" do
      assert {:error, [%Peri.Error{key: :name}]} = Span.new(type: :agent)
      assert {:error, [%Peri.Error{key: :name}]} = Span.new(type: :tool)
      assert {:ok, %Span{type: :llm, name: nil}} = Span.new(type: :llm)
      assert {:ok, %Span{type: :retriever, name: nil}} = Span.new(type: :retriever)
    end

    test "builds each type with its own fields" do
      assert {:ok, %Span{available_tools: ["search"], agent_handoffs: ["billing"]}} =
               Span.new(
                 type: :agent,
                 name: "support",
                 available_tools: ["search"],
                 agent_handoffs: ["billing"]
               )

      assert {:ok, %Span{model: "gpt-4o-mini", provider: "openai", token_intervals: intervals}} =
               Span.new(
                 type: :llm,
                 model: "gpt-4o-mini",
                 provider: "openai",
                 prompt: %{alias: "draft", version: "00.00.01"},
                 prompt_label: "prod",
                 token_intervals: %{1_700_000_000_000_001 => "Hel"}
               )

      assert intervals == %{1_700_000_000_000_001 => "Hel"}

      assert {:ok, %Span{embedder: "e5", top_k: 2, chunk_size: 512}} =
               Span.new(type: :retriever, embedder: "e5", top_k: 2, chunk_size: 512)

      assert {:ok, %Span{description: "Looks things up"}} =
               Span.new(type: :tool, name: "lookup", description: "Looks things up")
    end

    test "rejects a field that belongs to another span type" do
      assert {:error, [%Peri.Error{key: :model} = error]} =
               Span.new(type: :agent, name: "a", model: "gpt-4o")

      assert error.message =~ "not a field of an :agent span"

      assert {:error, [%Peri.Error{key: :available_tools}]} =
               Span.new(type: :tool, name: "t", available_tools: ["x"])

      assert {:error, [%Peri.Error{key: :description}]} = Span.new(description: "base")
      assert {:error, [%Peri.Error{key: :top_k}]} = Span.new(type: :llm, top_k: 3)
    end

    test "accepts another type's field left at its default, so a span round-trips" do
      {:ok, span} = Span.new(type: :llm, name: "generate", model: "gpt-4o-mini")

      assert {:ok, ^span} = span |> Map.from_struct() |> Span.new()
    end

    test "rejects an unknown type" do
      assert {:error, [%Peri.Error{key: :type}]} = Span.new(type: :workflow)
    end

    test "casts token counts and costs to floats, as pydantic's float fields" do
      assert {:ok, span} =
               Span.new(
                 type: :llm,
                 input_token_count: 42,
                 output_token_count: 7,
                 cost_per_input_token: 1.5e-7,
                 cost_per_output_token: 0
               )

      assert span.input_token_count === 42.0
      assert span.output_token_count === 7.0
      assert span.cost_per_input_token === 1.5e-7
      assert span.cost_per_output_token === 0.0
    end

    test "validates the field types" do
      assert {:error, [%Peri.Error{key: :status}]} = Span.new(status: :done)
      assert {:error, [%Peri.Error{key: :retrieval_context}]} = Span.new(retrieval_context: "x")
      assert {:error, [%Peri.Error{key: :top_k}]} = Span.new(type: :retriever, top_k: 2.5)
      assert {:error, [%Peri.Error{key: :children}]} = Span.new(children: [%{uuid: "c"}])
      assert {:error, [%Peri.Error{key: :llm_test_case}]} = Span.new(llm_test_case: %{})

      assert {:error, [%Peri.Error{key: :token_intervals}]} =
               Span.new(type: :llm, token_intervals: %{"1.5" => "Hel"})
    end

    test "builds tool calls from maps or structs" do
      assert {:ok, span} =
               Span.new(
                 tools_called: [%{"name" => "search", "inputParameters" => %{"q" => "x"}}],
                 expected_tools: [%ToolCall{name: "search"}]
               )

      assert [%ToolCall{name: "search", input_parameters: %{"q" => "x"}}] = span.tools_called
      assert [%ToolCall{name: "search", type: :function}] = span.expected_tools
    end

    test "takes metric specs: a module, a module with options, or a metric struct" do
      metric = struct(PatternMatch)

      assert {:ok, %Span{metrics: [ExactMatch, {ExactMatch, [threshold: 1.0]}, ^metric]}} =
               Span.new(metrics: [ExactMatch, {ExactMatch, threshold: 1.0}, metric])

      assert {:error, [%Peri.Error{key: :metrics}]} = Span.new(metrics: ["exact_match"])
      assert {:error, [%Peri.Error{key: :metrics}]} = Span.new(metrics: [nil])
      assert {:error, [%Peri.Error{key: :metrics}]} = Span.new(metrics: [{ExactMatch, %{}}])
    end

    test "takes children and a test case as structs" do
      {:ok, child} = Span.new(type: :tool, name: "lookup")
      test_case = %TestCase{input: "q", actual_output: "a"}

      assert {:ok, %Span{children: [^child], llm_test_case: ^test_case}} =
               Span.new(children: [child], llm_test_case: test_case)
    end
  end

  describe "new!/1" do
    test "raises on invalid attributes" do
      assert_raise ArgumentError, ~r/Invalid span/, fn -> Span.new!(type: :agent) end
    end
  end

  test "type/1 returns the span's type, deepeval's isinstance check" do
    assert Span.type(Span.new!(type: :retriever)) == :retriever
    assert Span.type(Span.new!([])) == :base
  end

  test "status_value/1 and type_value/1 give deepeval's enum values" do
    assert Enum.map([:success, :errored, :in_progress], &Span.status_value/1) ==
             ["SUCCESS", "ERRORED", "IN_PROGRESS"]

    assert Enum.map(Span.types(), &Span.type_value/1) ==
             ["base", "agent", "llm", "retriever", "tool"]
  end
end
