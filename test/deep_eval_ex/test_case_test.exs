defmodule DeepEvalEx.TestCaseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.TestCase

  doctest DeepEvalEx.TestCase

  describe "new/1" do
    test "creates a valid test case with required fields" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "What is the capital of France?",
                 actual_output: "Paris"
               )

      assert test_case.input == "What is the capital of France?"
      assert test_case.actual_output == "Paris"
    end

    test "creates test case with all fields" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "Question",
                 actual_output: "Answer",
                 expected_output: "Expected",
                 retrieval_context: ["context 1", "context 2"],
                 metadata: %{key: "value"},
                 name: "test-1",
                 tags: ["rag", "qa"]
               )

      assert test_case.expected_output == "Expected"
      assert test_case.retrieval_context == ["context 1", "context 2"]
      assert test_case.metadata == %{key: "value"}
      assert test_case.name == "test-1"
      assert test_case.tags == ["rag", "qa"]
    end

    test "returns error for missing required fields" do
      assert {:error, errors} = TestCase.new(%{})
      assert errors != nil
    end

    test "keeps context and retrieval_context separate, as deepeval's LLMTestCase" do
      assert {:ok, test_case} = TestCase.new(input: "Question", context: ["context 1"])

      assert test_case.context == ["context 1"]
      assert test_case.retrieval_context == nil

      assert {:ok, test_case} = TestCase.new(input: "Question", retrieval_context: ["chunk 1"])

      assert test_case.retrieval_context == ["chunk 1"]
      assert test_case.context == nil
    end
  end

  describe "new!/1" do
    test "creates test case and returns struct directly" do
      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer"
        )

      assert %TestCase{} = test_case
      assert test_case.input == "Question"
    end

    test "raises on invalid input" do
      assert_raise RuntimeError, ~r/Invalid test case/, fn ->
        TestCase.new!(%{})
      end
    end
  end

  describe "validate_params/2" do
    test "returns :ok when all params present" do
      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer",
          expected_output: "Expected"
        )

      assert :ok = TestCase.validate_params(test_case, [:input, :actual_output, :expected_output])
    end

    test "returns error with missing params" do
      test_case = TestCase.new!(input: "Question")

      assert {:error, {:missing_params, missing}} =
               TestCase.validate_params(test_case, [:input, :actual_output, :expected_output])

      assert :actual_output in missing
      assert :expected_output in missing
      refute :input in missing
    end
  end

  describe "validate_params/2, as deepeval's check_llm_test_case_params" do
    test "does not accept context for retrieval_context" do
      test_case = TestCase.new!(input: "Q", actual_output: "A", context: ["ctx"])

      assert {:error, {:missing_params, [:retrieval_context]}} =
               TestCase.validate_params(test_case, [:input, :actual_output, :retrieval_context])
    end

    test "does not accept retrieval_context for context" do
      test_case = TestCase.new!(input: "Q", actual_output: "A", retrieval_context: ["ctx"])

      assert {:error, {:missing_params, [:context]}} =
               TestCase.validate_params(test_case, [:input, :actual_output, :context])
    end

    test "lists missing params in the order they are required" do
      test_case = %TestCase{input: nil}

      assert {:error, {:missing_params, [:input, :expected_output, :retrieval_context]}} =
               TestCase.validate_params(test_case, [:input, :expected_output, :retrieval_context])
    end

    test "only counts nil as missing: empty lists and strings are present" do
      test_case = %TestCase{
        input: "",
        actual_output: "A",
        expected_output: "",
        context: [],
        retrieval_context: []
      }

      assert :ok =
               TestCase.validate_params(test_case, [
                 :input,
                 :actual_output,
                 :expected_output,
                 :context,
                 :retrieval_context
               ])
    end

    test "rejects an empty actual_output before looking for missing params" do
      test_case = %TestCase{input: "Q", actual_output: ""}

      assert {:error, {:empty_param, :actual_output}} =
               TestCase.validate_params(test_case, [:input, :actual_output, :retrieval_context])
    end

    test "accepts an empty actual_output a metric does not require" do
      test_case = %TestCase{input: "Q", actual_output: ""}

      assert :ok = TestCase.validate_params(test_case, [:input])
    end
  end

  describe "deepeval LLMTestCase fields" do
    test "accepts comments, token usage, completion time and flaky" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "Q",
                 comments: "Known edge case",
                 token_cost: 0.0042,
                 input_token_count: 120,
                 output_token_count: 48,
                 completion_time: 1.25,
                 flaky: true
               )

      assert test_case.comments == "Known edge case"
      assert test_case.token_cost == 0.0042
      assert test_case.input_token_count == 120
      assert test_case.output_token_count == 48
      assert test_case.completion_time == 1.25
      assert test_case.flaky == true
    end

    test "leaves optional fields nil and flaky false by default" do
      test_case = TestCase.new!(input: "Q")

      assert test_case.comments == nil
      assert test_case.token_cost == nil
      assert test_case.input_token_count == nil
      assert test_case.output_token_count == nil
      assert test_case.completion_time == nil
      assert test_case.flaky == false
      assert %TestCase{input: "Q"}.flaky == false
    end

    test "coerces integer token_cost and completion_time to floats" do
      test_case = TestCase.new!(input: "Q", token_cost: 1, completion_time: 2)

      assert test_case.token_cost === 1.0
      assert test_case.completion_time === 2.0
    end

    test "accepts the new fields with string keys" do
      test_case =
        TestCase.new!(%{
          "input" => "Q",
          "comments" => "note",
          "token_cost" => 0.5,
          "input_token_count" => 3,
          "output_token_count" => 4,
          "completion_time" => 0.25,
          "flaky" => true
        })

      assert test_case.comments == "note"
      assert test_case.token_cost == 0.5
      assert test_case.input_token_count == 3
      assert test_case.output_token_count == 4
      assert test_case.completion_time == 0.25
      assert test_case.flaky
    end

    test "rejects values of the wrong type" do
      assert {:error, _} = TestCase.new(input: "Q", comments: 1)
      assert {:error, _} = TestCase.new(input: "Q", token_cost: "cheap")
      assert {:error, _} = TestCase.new(input: "Q", input_token_count: 1.5)
      assert {:error, _} = TestCase.new(input: "Q", output_token_count: "4")
      assert {:error, _} = TestCase.new(input: "Q", completion_time: "fast")
      assert {:error, _} = TestCase.new(input: "Q", flaky: "yes")
    end
  end

  describe "tool calls" do
    alias DeepEvalEx.Schemas.ToolCall

    test "default type to :function and accept :mcp" do
      test_case =
        TestCase.new!(
          input: "Q",
          tools_called: [%{name: "search"}, %{name: "fs_read", type: :mcp}],
          expected_tools: [%{name: "search"}]
        )

      assert [%ToolCall{name: "search", type: :function}, %ToolCall{type: :mcp}] =
               test_case.tools_called

      assert [%ToolCall{type: :function}] = test_case.expected_tools
    end

    test "accept any JSON term as output" do
      test_case =
        TestCase.new!(
          input: "Q",
          tools_called: [
            %{name: "weather", output: %{"temp" => 18}},
            %{name: "count", output: 3},
            %{name: "list", output: ["a", "b"]}
          ]
        )

      assert Enum.map(test_case.tools_called, & &1.output) == [%{"temp" => 18}, 3, ["a", "b"]]
    end

    test "normalise string keys, inputParameters and deepeval type strings" do
      test_case =
        TestCase.new!(%{
          "input" => "Q",
          "tools_called" => [
            %{"name" => "search", "type" => "MCP", "inputParameters" => %{"q" => "x"}}
          ]
        })

      assert [%ToolCall{name: "search", type: :mcp, input_parameters: %{"q" => "x"}}] =
               test_case.tools_called
    end

    test "reject an unknown tool call type" do
      assert {:error, _} = TestCase.new(input: "Q", tools_called: [%{name: "s", type: :webhook}])
    end

    test "accept ToolCall structs" do
      test_case = TestCase.new!(input: "Q", tools_called: [%ToolCall{name: "search", type: :mcp}])
      assert [%ToolCall{name: "search", type: :mcp}] = test_case.tools_called
    end
  end

  describe "json_schema/0" do
    test "includes the deepeval LLMTestCase fields" do
      props = TestCase.json_schema()["properties"]

      assert props["comments"] == %{"type" => "string"}
      assert props["token_cost"] == %{"type" => "number"}
      assert props["input_token_count"] == %{"type" => "integer"}
      assert props["output_token_count"] == %{"type" => "integer"}
      assert props["completion_time"] == %{"type" => "number"}
      assert props["flaky"] == %{"type" => "boolean"}
      assert props["tools_called"]["items"]["properties"]["type"]["enum"] == ["function", "mcp"]
    end
  end
end
