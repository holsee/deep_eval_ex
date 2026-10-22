defmodule DeepEvalEx.SystemOne.StateTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.SystemOne.{Dumpable, EvalSpec, State}
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.TestRun.JSON

  doctest State

  defp encode(state), do: JSON.encode!(state, ensure_ascii: false)

  describe "single_turn/2" do
    test "sends populated params in the spec's order and drops empty ones" do
      test_case = %TestCase{
        input: "Café?",
        actual_output: "",
        expected_output: nil,
        retrieval_context: [],
        context: ["18°C"]
      }

      state =
        State.single_turn(
          [:context, :actual_output, :expected_output, :retrieval_context, "input"],
          test_case
        )

      assert encode(state) == ~s({"test_case": {"context": ["18°C"], "input": "Café?"}})
    end

    test "dumps tool calls as pydantic's model_dump(exclude_none=True)" do
      test_case = %TestCase{
        input: "Weather?",
        tools_called: [
          %ToolCall{
            name: "get_weather",
            type: :mcp,
            reasoning: "asked for weather",
            input_parameters: %{"city" => "Paris"},
            output: %{"temp_c" => 18}
          }
        ]
      }

      assert encode(State.single_turn([:tools_called, :expected_tools], test_case)) ==
               ~s({"test_case": {"tools_called": [{"name": "get_weather", "type": "MCP", ) <>
                 ~s("reasoning": "asked for weather", "output": {"temp_c": 18}, ) <>
                 ~s("input_parameters": {"city": "Paris"}}]}})
    end
  end

  describe "build/2" do
    test "drops an empty test_case and keeps the non-nil extra_state in order" do
      spec = %EvalSpec{
        evaluation_params: [:expected_output],
        extra_state: [{"zeta", 1}, {:alpha, [a: 1]}, {"skipped", nil}]
      }

      assert encode(State.build(spec, %TestCase{input: "Q"})) ==
               ~s({"zeta": 1, "alpha": [["a", 1]]})
    end

    test "an extra_state test_case replaces the test case in place" do
      spec = %EvalSpec{
        evaluation_params: [:input],
        extra_state: [extra: true, test_case: "replaced"]
      }

      assert encode(State.build(spec, %TestCase{input: "Q"})) ==
               ~s({"test_case": "replaced", "extra": true})
    end
  end

  describe "dump/1" do
    test "turns keys into strings, tuples into lists and atoms into names" do
      assert State.dump(%{1 => {:ok, nil}, key: :value}) == %{
               "1" => ["ok", nil],
               "key" => "value"
             }
    end

    test "sends a struct without a Dumpable implementation as text" do
      assert State.dump(~D[2026-10-22]) == "2026-10-22"
      assert State.dump(%URI{host: "example.com", scheme: "https"}) == "https://example.com"
      assert State.dump(MapSet.new([1])) == "MapSet.new([1])"
      assert Dumpable.dump(~D[2026-10-22]) == "2026-10-22"
    end
  end

  describe "merge/2" do
    defp object(pairs), do: Jason.OrderedObject.new(pairs)

    test "merges test case fields in place and appends new keys, as deepeval's _merge_states" do
      a = object([{"test_case", object([{"input", "Q"}])}, {"topics", ["x"]}])
      b = object([{"facts", ["f"]}, {"test_case", object([{"input", "Q"}, {"context", ["c"]}])}])

      assert encode(State.merge(a, b)) ==
               ~s({"test_case": {"input": "Q", "context": ["c"]}, "topics": ["x"], "facts": ["f"]})
    end

    test "keeps an equal key whatever its order, and refuses a different value" do
      a = object([{"tools", object([{"a", 1}, {"b", 2}])}])

      assert State.merge(a, object([{"tools", object([{"b", 2}, {"a", 1}])}])) == a
      assert State.merge(a, object([{"tools", object([{"a", 1}])}])) == nil
    end

    test "merges each turn's fields" do
      a = object([{"turns", [object([{"role", "user"}]), object([{"role", "assistant"}])]}])
      b = object([{"turns", [object([{"content", "hi"}]), object([{"content", "hello"}])]}])

      assert encode(State.merge(a, b)) ==
               ~s({"turns": [{"role": "user", "content": "hi"}, ) <>
                 ~s({"role": "assistant", "content": "hello"}]})
    end
  end
end
