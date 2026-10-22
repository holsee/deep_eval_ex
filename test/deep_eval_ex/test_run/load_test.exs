defmodule DeepEvalEx.TestRun.LoadTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Result, TestRun}
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase, as: EvalTestCase
  alias DeepEvalEx.TestRun.{JSON, MetricData}

  doctest TestRun, only: [from_map: 1]

  @fixtures Path.expand("../../fixtures/deepeval", __DIR__)
  # Export scenarios, plus round_trip/: richer runs (traces, prompts, a
  # dataset) DeepEvalEx cannot produce but must load and write back as is.
  @files ["*/test_run.json", "round_trip/*/test_run.json"]
         |> Enum.flat_map(&Path.wildcard(Path.join(@fixtures, &1)))
         |> Enum.sort()

  for file <- @files do
    @external_resource file
  end

  defp fixture(scenario), do: Path.join([@fixtures, scenario, "test_run.json"])

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)

  defp load!(path) do
    assert {:ok, %TestRun{} = test_run} = TestRun.load(path)
    test_run
  end

  defp from_map!(map) do
    assert {:ok, %TestRun{} = test_run} = TestRun.from_map(map)
    test_run
  end

  defp encode(test_run), do: test_run |> TestRun.to_map() |> JSON.encode!()

  test "finds the deepeval fixtures" do
    assert length(@files) >= 5
  end

  describe "load/1 round trip" do
    for file <- @files do
      scenario = file |> Path.dirname() |> Path.relative_to(@fixtures)

      test "re-encodes deepeval's #{scenario} test run byte for byte" do
        path = unquote(file)

        assert path |> load!() |> encode() == File.read!(path)
      end
    end

    test "re-encodes a run built by from_results/3 byte for byte" do
      test_cases = [
        %EvalTestCase{
          input: "q",
          actual_output: "a",
          tools_called: [%ToolCall{name: "t", type: :mcp, input_parameters: %{"x" => 1}}],
          metadata: %{"k" => [1, 2.5, nil]}
        }
      ]

      results = [
        [
          Result.new(metric: "M", score: 0.75, evaluation_cost: 0.5, input_tokens: 3),
          Result.error("E", "boom", threshold: 0.5)
        ]
      ]

      json =
        test_cases
        |> TestRun.from_results(results, run_durations: [1.5], identifier: "id")
        |> encode()

      assert json |> Jason.decode!(objects: :ordered_objects) |> from_map!() |> encode() == json
    end
  end

  describe "load/1" do
    test "reads test cases, metric data and run totals" do
      test_run = load!(fixture("hyperparameters"))

      assert test_run.identifier == "nightly-2026-10-22"
      assert {"temperature", "0.7"} in test_run.hyperparameters
      assert test_run.test_passed == 2
      assert test_run.test_failed == 0
      assert test_run.evaluation_cost == 0.000642

      assert [%TestRun.TestCase{name: "test_case_0", order: 0, run_duration: 0} | _] =
               test_run.test_cases

      assert [%{metric: "Exact Match", scores: [1.0, 1.0], passes: 2, fails: 0, errors: 0} | _] =
               test_run.metrics_scores
    end

    test "reads the dataset keys and keeps prompts, trace metric scores and traces" do
      test_run = load!(fixture("round_trip/traced_dataset"))

      assert test_run.dataset_alias == "support-goldens"
      assert test_run.dataset_id == "ds_parity_0001"
      assert test_run.dataset_version == "3"
      assert test_run.test_file == nil
      assert test_run.official == false
      assert test_run.identifier == "traced-dataset"
      assert test_run.conversational_test_cases == []

      assert [%Jason.OrderedObject{} = system, %Jason.OrderedObject{} = chat] = test_run.prompts
      assert system["alias"] == "support-system"
      assert chat["alias"] == "support-chat"

      assert %Jason.OrderedObject{} = test_run.trace_metrics_scores
      assert test_run.trace_metrics_scores["retriever"]["retrieve"]["Span Judge"]["passes"] == 2

      assert [%TestRun.TestCase{trace: %Jason.OrderedObject{} = trace} | _] = test_run.test_cases
      assert [span] = trace["retrieverSpans"]
      assert span["name"] == "retrieve"
      assert test_run.test_passed + test_run.test_failed == length(test_run.test_cases)
    end

    test "keeps errors, evaluation model, tokens, cost, strict mode and flakiness" do
      [test_case | _] = load!(fixture("metric_error")).test_cases

      assert [
               %MetricData{name: "Exact Match", score: 1.0, success: true},
               %MetricData{
                 name: "Flaky Judge",
                 score: nil,
                 reason: nil,
                 success: false,
                 threshold: 0.5,
                 error: "judge returned invalid JSON",
                 strict_mode: false,
                 flaky: false
               },
               %MetricData{
                 name: "Stub Judge",
                 evaluation_model: "gpt-4o-mini",
                 evaluation_cost: 0.000321,
                 input_tokens: 1234,
                 output_tokens: 56
               }
             ] = test_case.metrics_data
    end

    test "reads tool calls as ToolCall structs" do
      [test_case | _] = load!(fixture("rag_and_tools")).test_cases

      assert [%ToolCall{name: "get_weather", type: :function} = tool, %ToolCall{}] =
               test_case.tools_called

      assert tool.input_parameters["city"] == "Paris"
      assert tool.output["temp_c"] == 18.0
      assert test_case.retrieval_context == ["Paris: 18°C, partly cloudy.", "Lyon: 21°C, sunny."]
    end

    test "returns file and JSON errors" do
      assert {:error, :enoent} = TestRun.load("does/not/exist.json")

      path = Path.join(System.tmp_dir!(), "deep_eval_ex_bad_#{System.unique_integer()}.json")
      File.write!(path, "{not json")
      on_exit(fn -> File.rm(path) end)

      assert {:error, %Jason.DecodeError{}} = TestRun.load(path)
    end
  end

  describe "from_map/1" do
    test "accepts plain maps as well as ordered objects" do
      map = fixture("llm_metric") |> File.read!() |> Jason.decode!()
      test_run = from_map!(map)

      assert [%TestRun.TestCase{name: "test_case_0"}, %TestRun.TestCase{name: "memo"}] =
               test_run.test_cases

      assert test_run.evaluation_cost == 0.005642
    end

    test "tolerates missing optional keys, filling deepeval's defaults" do
      test_run =
        from_map!(%{
          "testCases" => [
            %{"name" => "a", "input" => "q", "metricsData" => [%{"name" => "M", "score" => 1.0}]},
            %{"name" => "b"}
          ]
        })

      assert [
               %TestRun.TestCase{
                 name: "a",
                 input: "q",
                 flaky: false,
                 success: nil,
                 run_duration: 0,
                 order: 0,
                 evaluation_cost: nil,
                 metrics_data: [
                   %MetricData{name: "M", score: 1.0, success: nil, strict_mode: false}
                 ]
               },
               %TestRun.TestCase{name: "b", success: nil, metrics_data: [], order: 1}
             ] = test_run.test_cases

      # A metric without `success` has no verdict, as deepeval's MetricData
      # defaults it to None: it is counted as an error and fails nothing.
      assert test_run.metrics_scores == [
               %{metric: "M", scores: [], passes: 0, fails: 0, errors: 1}
             ]

      # Without "success", deepeval's LLMApiTestCase.success is None: the
      # test case neither passed nor failed.
      assert test_run.test_passed == 0
      assert test_run.test_failed == 0
      assert test_run.run_duration == 0.0
      assert test_run.evaluation_cost == nil
      assert test_run.identifier == nil
      assert test_run.hyperparameters == nil
      assert test_run.prompts == nil
      assert test_run.conversational_test_cases == []
      assert test_run.official == false
    end

    test "reads explicit JSON nulls as missing keys" do
      # deepeval saves with exclude_none=True, so it never writes null: a
      # test case whose success is None has no "success" key at all.
      missing = %{"name" => "a", "metricsData" => [%{"name" => "M", "success" => true}]}

      nulls =
        Map.merge(missing, %{
          "success" => nil,
          "flaky" => nil,
          "runDuration" => nil,
          "order" => nil,
          "evaluationCost" => nil,
          "metricsData" => [
            %{"name" => "M", "success" => true, "strictMode" => nil, "score" => nil}
          ]
        })

      run_with_nulls = %{
        "testCases" => [nulls],
        "metricsScores" => nil,
        "testPassed" => nil,
        "testFailed" => nil,
        "runDuration" => nil,
        "identifier" => nil,
        "hyperparameters" => nil,
        "testFile" => nil,
        "prompts" => nil,
        "traceMetricsScores" => nil,
        "conversationalTestCases" => nil,
        "datasetAlias" => nil,
        "official" => nil
      }

      assert from_map!(run_with_nulls) == from_map!(%{"testCases" => [missing]})

      assert [%TestRun.TestCase{success: nil, flaky: false, run_duration: 0, order: 0}] =
               from_map!(run_with_nulls).test_cases

      refute encode(from_map!(run_with_nulls)) =~ "null"
    end

    test "loads an empty object as an empty run" do
      assert from_map!(%{}) == %TestRun{}
    end

    test "keeps the keys DeepEvalEx does not model and writes them back in place" do
      # deepeval's own keys go back where its models declare them; keys
      # deepeval does not know either follow them, in the file's order.
      metric_data =
        ordered([
          {"name", "M"},
          {"threshold", 0.5},
          {"success", true},
          {"score", 1.0},
          {"strictMode", false},
          {"flaky", false},
          {"expectationsData", ordered([{"expectations", ["x"]}])},
          {"futureMetricKey", [1, 2.5]}
        ])

      test_case =
        ordered([
          {"expectationsData", ordered([{"evaluationCost", 0.25}])},
          {"name", "a"},
          {"input", "q"},
          {"flaky", false},
          {"imagesMapping", ordered([{"img_0", ordered([{"url", "https://x/0.png"}])}])},
          {"success", true},
          {"metricsData", [metric_data]},
          {"runDuration", 0},
          {"order", 0},
          {"trace", ordered([{"uuid", "1"}, {"baseSpans", []}])},
          {"futureTestCaseKey", nil}
        ])

      file =
        ordered([
          {"testFile", "test_chatbot.py"},
          {"testCases", [test_case]},
          {"conversationalTestCases", [ordered([{"name", "conv"}, {"success", false}])]},
          {"metricsScores",
           [
             ordered([
               {"metric", "M"},
               {"scores", [1.0]},
               {"passes", 1},
               {"fails", 0},
               {"errors", 0}
             ])
           ]},
          {"traceMetricsScores", ordered([{"agent", ordered([])}, {"tool", ordered([])}])},
          {"identifier", "run"},
          {"hyperparameters", ordered([{"model", "gpt-4o"}])},
          {"prompts", [ordered([{"alias", "p"}, {"interpolation_type", "FSTRING"}])]},
          {"testPassed", 1},
          {"testFailed", 1},
          {"runDuration", 1.5},
          {"evaluationCost", 0.25},
          {"datasetAlias", "golden"},
          {"datasetId", "ds_1"},
          {"datasetVersion", "2"},
          {"official", true},
          {"futureRunKey", ordered([{"a", 1}])}
        ])

      test_run = from_map!(file)

      assert test_run.test_file == "test_chatbot.py"

      assert {test_run.dataset_alias, test_run.dataset_id, test_run.dataset_version} ==
               {"golden", "ds_1", "2"}

      assert test_run.official == true
      assert [%Jason.OrderedObject{}] = test_run.conversational_test_cases
      assert test_run.extra == [{"futureRunKey", ordered([{"a", 1}])}]

      assert [
               %TestRun.TestCase{
                 trace: %Jason.OrderedObject{},
                 extra: [{"futureTestCaseKey", nil}]
               }
             ] =
               test_run.test_cases

      assert encode(test_run) == JSON.encode!(file)
    end

    test "keeps a test case without success as neither passed nor failed" do
      # deepeval's LLMApiTestCase.success is None until a metric sets it and
      # is then left out of the file; calculate_test_passes_and_fails skips it.
      test_run =
        from_map!(%{
          "testCases" => [
            %{"name" => "none", "metricsData" => [%{"name" => "M", "score" => 0.5}]},
            %{"name" => "passed", "success" => true},
            %{"name" => "failed", "success" => false}
          ]
        })

      assert [%{success: nil}, %{success: true}, %{success: false}] = test_run.test_cases
      assert {test_run.test_passed, test_run.test_failed} == {1, 1}

      [none | _] = test_run |> encode() |> Jason.decode!() |> Map.fetch!("testCases")
      refute Map.has_key?(none, "success")
    end

    test "counts conversational test cases' success when the totals are missing" do
      test_run =
        from_map!(%{
          "testCases" => [%{"name" => "a", "success" => true}],
          "conversationalTestCases" => [%{"name" => "c", "success" => false}, %{"name" => "d"}]
        })

      assert {test_run.test_passed, test_run.test_failed} == {1, 1}
    end

    test "keeps a metric's verboseLogs, written last as deepeval's MetricData" do
      test_run =
        from_map!(%{
          "testCases" => [
            %{
              "name" => "a",
              "metricsData" => [
                %{"name" => "M", "success" => true, "verboseLogs" => "Verdicts:\n[]"}
              ]
            }
          ]
        })

      assert [%{metrics_data: [%{verbose_logs: "Verdicts:\n[]"}]}] = test_run.test_cases
      assert encode(test_run) =~ ~s("flaky": false, "verboseLogs": "Verdicts:\\n[]"})
    end

    test "rejects test cases and metric data without a name" do
      assert {:error, {:invalid_test_run, "testCases[1].name" <> _}} =
               TestRun.from_map(%{"testCases" => [%{"name" => "a"}, %{"input" => "q"}]})

      assert {:error, {:invalid_test_run, "testCases[0].metricsData[0].name" <> _}} =
               TestRun.from_map(%{"testCases" => [%{"name" => "a", "metricsData" => [%{}]}]})
    end

    test "rejects values of the wrong shape" do
      assert {:error, {:invalid_test_run, "test run" <> _}} = TestRun.from_map([1, 2])

      assert {:error, {:invalid_test_run, "testCases" <> _}} =
               TestRun.from_map(%{"testCases" => "nope"})

      assert {:error, {:invalid_test_run, "testCases[0].toolsCalled[0].type" <> _}} =
               TestRun.from_map(%{
                 "testCases" => [
                   %{"name" => "a", "toolsCalled" => [%{"name" => "t", "type" => "X"}]}
                 ]
               })
    end
  end

  describe "to_results/1" do
    test "returns DeepEvalEx test cases and results, like evaluate_run/3" do
      {[test_case | _], [results | _]} =
        fixture("rag_and_tools") |> load!() |> TestRun.to_results()

      assert %EvalTestCase{
               name: "test_case_0",
               input: "What's the weather in Paris?",
               completion_time: 1.25,
               token_cost: 0.00042,
               tools_called: [%ToolCall{name: "get_weather"}, %ToolCall{name: "format_answer"}],
               expected_tools: [%ToolCall{name: "get_weather"}]
             } = test_case

      assert [
               %Result{metric: "Exact Match", score: +0.0, success: false, threshold: 1.0},
               %Result{
                 metric: "Stub Judge",
                 score: 0.75,
                 evaluation_model: "gpt-4o-mini",
                 evaluation_cost: 0.000321,
                 input_tokens: 1234,
                 output_tokens: 56
               }
             ] = results
    end

    test "returns errored results for errored metric data" do
      {_test_cases, [[_exact, flaky, _stub] | _]} =
        fixture("metric_error") |> load!() |> TestRun.to_results()

      assert Result.errored?(flaky)
      assert flaky.error == "judge returned invalid JSON"
      assert flaky.score == nil
    end

    test "keeps missing tool call lists nil and empty ones empty, as deepeval's None" do
      cases = [
        %{"name" => "a", "input" => "q"},
        %{"name" => "b", "input" => "q", "toolsCalled" => [], "expectedTools" => []}
      ]

      {[missing, empty], _results} = TestRun.to_results(from_map!(%{"testCases" => cases}))

      assert missing.tools_called == nil
      assert missing.expected_tools == nil
      assert empty.tools_called == []
      assert empty.expected_tools == []
    end
  end
end
