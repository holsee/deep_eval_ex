defmodule DeepEvalEx.Dataset.GoldenTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestCase

  doctest DeepEvalEx.Dataset.Golden

  describe "new/1" do
    test "builds a golden from deepeval's field names, as atoms or strings" do
      attrs = %{
        "input" => "What's the weather in Paris?",
        "actual_output" => "18°C",
        "expected_output" => "18°C, partly cloudy.",
        "context" => ["Paris is in France."],
        "retrieval_context" => ["Paris: 18°C", %{"context" => "Sunny", "source" => "wiki"}],
        "additional_metadata" => %{"source" => "weather-bot"},
        "comments" => "Hand-checked",
        "tools_called" => [%{"name" => "get_weather", "inputParameters" => %{"city" => "Paris"}}],
        "expected_tools" => [%{"name" => "get_weather", "type" => "MCP"}],
        "token_cost" => 1,
        "input_token_count" => 120,
        "output_token_count" => 18,
        "source_file" => "weather.pdf",
        "name" => "paris_weather",
        "custom_column_key_values" => %{"team" => "weather"},
        "expectations" => %{"must" => [" Mention the temperature "]},
        "expected_labels" => %{"tone" => "neutral"}
      }

      assert {:ok, golden} = Golden.new(attrs)

      assert %Golden{
               input: "What's the weather in Paris?",
               actual_output: "18°C",
               expected_output: "18°C, partly cloudy.",
               context: ["Paris is in France."],
               retrieval_context: [
                 "Paris: 18°C",
                 %RetrievedContextData{context: "Sunny", source: "wiki"}
               ],
               additional_metadata: %{"source" => "weather-bot"},
               comments: "Hand-checked",
               tools_called: [
                 %ToolCall{name: "get_weather", input_parameters: %{"city" => "Paris"}}
               ],
               expected_tools: [%ToolCall{name: "get_weather", type: :mcp}],
               token_cost: 1.0,
               input_token_count: 120,
               output_token_count: 18,
               source_file: "weather.pdf",
               name: "paris_weather",
               custom_column_key_values: %{"team" => "weather"},
               expectations: %{
                 model: nil,
                 eval_mode: nil,
                 must: ["Mention the temperature"],
                 must_not: []
               },
               expected_labels: %{"tone" => "neutral"}
             } = golden

      assert Golden.new!(input: "Q", source_file: "a.txt", token_cost: 0.5).source_file ==
               "a.txt"
    end

    test "accepts the camelCase aliases deepeval's Golden validates, camelCase first" do
      golden =
        Golden.new!(%{
          "input" => "Q",
          "tokenCost" => 2,
          "token_cost" => 1,
          "inputTokenCount" => 3,
          "outputTokenCount" => 4,
          "expectedLabels" => %{"tone" => "calm"},
          "expected_labels" => %{"tone" => "neutral"}
        })

      assert %Golden{
               token_cost: 2.0,
               input_token_count: 3,
               output_token_count: 4,
               expected_labels: %{"tone" => "calm"}
             } = golden

      assert Golden.new!(input: "Q", tokenCost: 0.5).token_cost == 0.5
    end

    test "drops camelCase keys deepeval only serialises, and any unknown key" do
      # deepeval 4.3.1's Golden(actualOutput=...) ignores the key: these are
      # serialization aliases only, and the model is extra="ignore"
      golden =
        Golden.new!(%{
          "input" => "Q",
          "actualOutput" => "A",
          "expectedOutput" => "E",
          "retrievalContext" => ["r"],
          "additionalMetadata" => %{"a" => 1},
          "toolsCalled" => [%{"name" => "t"}],
          "expectedTools" => [%{"name" => "t"}],
          "sourceFile" => "f",
          "customColumnKeyValues" => %{"k" => "v"},
          "id" => "golden-1",
          "multimodal" => true,
          "not_a_field_#{System.unique_integer([:positive])}" => 1
        })

      assert golden == %Golden{input: "Q"}
    end

    test "rejects what deepeval's Golden rejects" do
      assert {:error, _} = Golden.new(actual_output: "A")
      assert {:error, _} = Golden.new(input: "Q", custom_column_key_values: %{"a" => 1})
      assert {:error, _} = Golden.new(input: "Q", expected_labels: %{"tone" => :calm})
      assert {:error, _} = Golden.new(input: "Q", expectations: %{"must" => [" "]})
      assert {:error, _} = Golden.new(input: "Q", tools_called: [%{"type" => "FUNCTION"}])
      assert_raise RuntimeError, ~r/Invalid golden/, fn -> Golden.new!(input: 1) end
    end
  end

  describe "to_test_case/1" do
    test "carries the fields deepeval's convert_goldens_to_test_cases carries" do
      golden =
        Golden.new!(
          input: "Q",
          actual_output: "A",
          expected_output: "E",
          context: ["c"],
          retrieval_context: [%RetrievedContextData{context: "r", source: "s"}],
          tools_called: [%{name: "t"}],
          expected_tools: [%{name: "u"}],
          token_cost: 0.1,
          input_token_count: 1,
          output_token_count: 2,
          name: "n",
          comments: "note",
          additional_metadata: %{"m" => 1},
          expected_labels: %{"tone" => "calm"},
          expectations: %{must: ["Be brief"]},
          source_file: "f.pdf",
          custom_column_key_values: %{"k" => "v"}
        )

      assert Golden.to_test_case(golden) == %TestCase{
               input: "Q",
               actual_output: "A",
               expected_output: "E",
               context: ["c"],
               retrieval_context: [%RetrievedContextData{context: "r", source: "s"}],
               tools_called: [%ToolCall{name: "t"}],
               expected_tools: [%ToolCall{name: "u"}],
               token_cost: 0.1,
               input_token_count: 1,
               output_token_count: 2,
               name: "n",
               comments: "note",
               metadata: %{"m" => 1},
               expected_labels: %{"tone" => "calm"},
               expectations: %{model: nil, eval_mode: nil, must: ["Be brief"], must_not: []}
             }
    end
  end

  describe "from_test_case/1" do
    test "carries the fields deepeval's convert_test_cases_to_goldens carries" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          expected_output: "E",
          context: ["c"],
          retrieval_context: ["r", %RetrievedContextData{context: "r2", source: "s"}],
          tools_called: [%{name: "t"}],
          expected_tools: [%{name: "u"}],
          token_cost: 0.1,
          input_token_count: 1,
          output_token_count: 2,
          metadata: %{"m" => 1},
          expectations: %{"mustNot" => ["Guess"]},
          name: "n",
          comments: "note",
          tags: ["t"],
          completion_time: 1.0,
          flaky: true,
          expected_labels: %{"tone" => "calm"},
          custom_column_key_values: %{"k" => "v"}
        )

      # deepeval leaves out name, comments, tags, completion_time, flaky,
      # expected_labels and custom_column_key_values
      assert Golden.from_test_case(test_case) == %Golden{
               input: "Q",
               actual_output: "A",
               expected_output: "E",
               context: ["c"],
               retrieval_context: ["r", %RetrievedContextData{context: "r2", source: "s"}],
               tools_called: [%ToolCall{name: "t"}],
               expected_tools: [%ToolCall{name: "u"}],
               token_cost: 0.1,
               input_token_count: 1,
               output_token_count: 2,
               additional_metadata: %{"m" => 1},
               expectations: %{model: nil, eval_mode: nil, must: [], must_not: ["Guess"]}
             }
    end
  end

  describe "list conversions" do
    test "convert_goldens_to_test_cases/1 and convert_test_cases_to_goldens/1 keep the order" do
      goldens = [Golden.new!(input: "one"), Golden.new!(input: "two")]

      test_cases = Golden.convert_goldens_to_test_cases(goldens)
      assert Enum.map(test_cases, & &1.input) == ["one", "two"]
      assert Golden.convert_test_cases_to_goldens(test_cases) == goldens
    end
  end
end
