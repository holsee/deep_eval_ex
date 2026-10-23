defmodule DeepEvalEx.TestCaseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
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

  describe "new/1 with RetrievedContextData" do
    test "accepts RetrievedContextData structs mixed with strings, in order" do
      data = %RetrievedContextData{context: "Paris is in France.", source: "wiki"}

      assert {:ok, test_case} =
               TestCase.new(input: "Q", retrieval_context: [data, "plain chunk"])

      assert test_case.retrieval_context == [data, "plain chunk"]
    end

    test "builds RetrievedContextData from maps with context and source" do
      assert {:ok, test_case} =
               TestCase.new(%{
                 "input" => "Q",
                 "retrievalContext" => [
                   %{"context" => "Paris is in France.", "source" => "wiki"},
                   %{context: "Lyon too.", source: "atlas"}
                 ]
               })

      assert test_case.retrieval_context == [
               %RetrievedContextData{context: "Paris is in France.", source: "wiki"},
               %RetrievedContextData{context: "Lyon too.", source: "atlas"}
             ]
    end

    test "rejects other items, as deepeval's validate_input" do
      assert {:error, _} = TestCase.new(input: "Q", retrieval_context: [1])
      assert {:error, _} = TestCase.new(input: "Q", retrieval_context: [%{context: "no source"}])
    end

    test "keeps context a list of strings only" do
      data = %RetrievedContextData{context: "Paris is in France.", source: "wiki"}

      assert {:error, _} = TestCase.new(input: "Q", context: [data])
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

  describe "new/1 with deepeval keys" do
    @fixture Path.expand("../fixtures/test_case/deepeval_llm_test_case.json", __DIR__)

    test "loads a deepeval-shaped JSON test case as deepeval 4.3.1's LLMTestCase does" do
      attrs = @fixture |> File.read!() |> Jason.decode!()

      assert {:ok, test_case} = TestCase.new(attrs)

      assert test_case.input == "What's the weather in Paris?"
      assert test_case.actual_output == "It is 18°C and partly cloudy in Paris."
      assert test_case.expected_output == "18°C, partly cloudy."
      assert test_case.context == ["Paris is the capital of France."]
      assert test_case.retrieval_context == ["Paris: 18°C, partly cloudy."]
      assert test_case.metadata == %{"source" => "weather-bot", "version" => 2}
      assert test_case.comments == "Hand-checked by the weather team."
      assert test_case.token_cost == 0.0021
      assert test_case.input_token_count == 120
      assert test_case.output_token_count == 18
      assert test_case.completion_time == 2.0
      assert test_case.flaky == true
      assert test_case.name == "paris_weather"
      assert test_case.tags == ["weather", "tools"]
      assert test_case.custom_column_key_values == %{"team" => "weather", "region" => "eu"}
      assert test_case.expected_labels == %{"tone" => "neutral"}

      assert [
               %ToolCall{
                 name: "get_weather",
                 type: :function,
                 description: "Fetch current weather for a city",
                 input_parameters: %{"city" => "Paris"},
                 output: %{"temp_c" => 18, "conditions" => "partly cloudy"}
               }
             ] = test_case.tools_called

      assert [%ToolCall{name: "get_weather", input_parameters: %{"city" => "Paris"}}] =
               test_case.expected_tools
    end

    test "accepts every camelCase alias of deepeval's LLMTestCase" do
      attrs = %{
        "input" => "Q",
        "actualOutput" => "A",
        "expectedOutput" => "E",
        "retrievalContext" => ["r"],
        "toolsCalled" => [%{"name" => "search"}],
        "expectedTools" => [%{"name" => "lookup"}],
        "tokenCost" => 0.5,
        "inputTokenCount" => 3,
        "outputTokenCount" => 4,
        "completionTime" => 1.5,
        "customColumnKeyValues" => %{"k" => "v"},
        "expectedLabels" => %{"c" => "l"}
      }

      assert {:ok, test_case} = TestCase.new(attrs)

      assert %TestCase{
               actual_output: "A",
               expected_output: "E",
               retrieval_context: ["r"],
               tools_called: [%ToolCall{name: "search"}],
               expected_tools: [%ToolCall{name: "lookup"}],
               token_cost: 0.5,
               input_token_count: 3,
               output_token_count: 4,
               completion_time: 1.5,
               custom_column_key_values: %{"k" => "v"},
               expected_labels: %{"c" => "l"}
             } = test_case
    end

    test "accepts additionalMetadata and additional_metadata for metadata" do
      assert TestCase.new!(%{"input" => "Q", "additionalMetadata" => %{"a" => 1}}).metadata ==
               %{"a" => 1}

      assert TestCase.new!(%{"input" => "Q", "additional_metadata" => %{"b" => 2}}).metadata ==
               %{"b" => 2}

      assert TestCase.new!(input: "Q", additional_metadata: %{c: 3}).metadata == %{c: 3}
    end

    test "prefers the alias deepeval lists first when several are given" do
      test_case =
        TestCase.new!(%{
          "input" => "Q",
          "actual_output" => "snake",
          "actualOutput" => "camel",
          "metadata" => %{"a" => 1},
          "additional_metadata" => %{"b" => 2}
        })

      assert test_case.actual_output == "camel"
      assert test_case.metadata == %{"a" => 1}
    end

    test "accepts camelCase atom keys" do
      assert TestCase.new!(input: "Q", actualOutput: "A").actual_output == "A"
    end

    test "drops unknown string keys instead of failing to convert them to atoms" do
      key = "not_a_deepeval_field_#{System.unique_integer([:positive])}"

      assert {:ok, test_case} =
               TestCase.new(%{
                 "input" => "Q",
                 key => "ignored",
                 "actualOutput" => "A",
                 "toolsCalled" => [%{"name" => "search", "inputParameters" => %{"q" => "x"}}]
               })

      assert test_case.actual_output == "A"
      assert [%ToolCall{name: "search", input_parameters: %{"q" => "x"}}] = test_case.tools_called
    end

    test "drops unknown atom keys and deepeval fields DeepEvalEx does not port" do
      assert {:ok, test_case} =
               TestCase.new(%{
                 "input" => "Q",
                 "mcpServers" => [],
                 "success" => true,
                 :bogus => 1
               })

      refute Map.has_key?(test_case, :bogus)
      refute Map.has_key?(test_case, :mcp_servers)
      refute Map.has_key?(test_case, :success)
    end

    test "does not take a dataset rank, deepeval's private _dataset_rank" do
      assert {:ok, %TestCase{dataset_rank: nil}} =
               TestCase.new(%{"input" => "Q", "dataset_rank" => 3, "_dataset_rank" => 3})
    end

    test "does not take a trace dict, deepeval's private _trace_dict" do
      assert {:ok, %TestCase{trace_dict: nil}} =
               TestCase.new(%{"input" => "Q", "trace_dict" => %{}, "_trace_dict" => %{}})
    end

    test "requires custom_column_key_values and expected_labels to map strings to strings" do
      assert {:error, _} = TestCase.new(input: "Q", custom_column_key_values: %{"a" => 1})
      assert {:error, _} = TestCase.new(input: "Q", expected_labels: %{"tone" => :neutral})
    end

    test "keeps expectations as deepeval's Expectations data" do
      assert TestCase.new!(%{"input" => "Q", "expectations" => %{"mustNot" => [" Guess "]}}).expectations ==
               %{model: nil, eval_mode: nil, must: [], must_not: ["Guess"]}

      assert TestCase.new!(input: "Q").expectations == nil
      assert {:error, _} = TestCase.new(input: "Q", expectations: %{"must" => [""]})
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

      assert props["custom_column_key_values"] == %{
               "type" => "object",
               "additionalProperties" => %{"type" => "string"}
             }

      assert props["expected_labels"] == props["custom_column_key_values"]

      assert props["expectations"]["properties"]["must_not"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert props["tools_called"]["items"]["properties"]["type"]["enum"] == ["function", "mcp"]
    end
  end

  describe "images and multimodal" do
    setup do
      %{
        chart: DeepEvalEx.MLLMImage.new!(url: "https://example.com/chart.png", id: "chart"),
        dot: DeepEvalEx.MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "dot")
      }
    end

    test "is set by a placeholder in the input, outputs, context or retrieval context" do
      for attrs <- [
            [input: "see [DEEPEVAL:IMAGE:a]"],
            [actual_output: "[DEEPEVAL:PDF:doc]"],
            [expected_output: "[DEEPEVAL:IMAGE:a]"],
            [context: ["[DEEPEVAL:IMAGE:a]"]],
            [retrieval_context: ["[DEEPEVAL:IMAGE:a]"]],
            [retrieval_context: [%{context: "[DEEPEVAL:IMAGE:a]", source: "s"}]]
          ] do
        attrs = Keyword.put_new(attrs, :input, "Q")
        assert TestCase.new!(attrs).multimodal, inspect(attrs)
      end

      refute TestCase.new!(input: "Q", actual_output: "A").multimodal
    end

    test "is kept when given" do
      assert TestCase.new!(input: "Q", multimodal: true).multimodal
    end

    test "keeps the images as a map of id to image", %{chart: chart, dot: dot} do
      test_case = TestCase.new!(input: "What is #{chart}?", images: [chart, dot])

      assert test_case.images == %{"chart" => chart, "dot" => dot}
    end

    test "builds images from their attributes, as an export's imagesMapping holds them",
         %{dot: dot} do
      test_case =
        TestCase.new!(%{
          "input" => "What is #{dot}?",
          "imagesMapping" => %{
            "dot" => %{"dataBase64" => "AAAA", "mimeType" => "image/png", "_id" => "dot"}
          }
        })

      assert test_case.images == %{"dot" => dot}
    end

    test "rejects an invalid image" do
      assert {:error, _} = TestCase.new(input: "Q", images: [%{data_base64: "AAAA"}])
    end

    test "images_mapping/1 is the images the placeholders name", %{chart: chart, dot: dot} do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "It is #{chart}.",
          retrieval_context: ["#{dot}", %{context: "unnamed", source: "s"}],
          images: [chart, dot]
        )

      assert TestCase.images_mapping(test_case) == %{"chart" => chart, "dot" => dot}
      assert TestCase.images_mapping(TestCase.new!(input: "Q", images: [chart])) == nil
    end

    test "images_mapping_dump/1 orders the images by first appearance", %{chart: chart, dot: dot} do
      test_case =
        TestCase.new!(input: "#{dot}", actual_output: "#{chart} #{dot}", images: [chart, dot])

      assert test_case |> TestCase.images_mapping_dump() |> Jason.encode!() =~
               ~r/\A\{"dot":\{.*\},"chart":\{.*\}\}\z/
    end
  end
end
