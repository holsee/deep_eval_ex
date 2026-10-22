defmodule DeepEvalEx.TestRun.LoadTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Result, TestRun}
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase, as: EvalTestCase
  alias DeepEvalEx.TestRun.{JSON, MetricData}

  doctest TestRun, only: [from_map: 1]

  @fixtures Path.expand("../../fixtures/deepeval", __DIR__)
  @files @fixtures |> Path.join("*/test_run.json") |> Path.wildcard() |> Enum.sort()

  for file <- @files do
    @external_resource file
  end

  defp fixture(scenario), do: Path.join([@fixtures, scenario, "test_run.json"])

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
      scenario = file |> Path.dirname() |> Path.basename()

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
                 success: false,
                 run_duration: 0,
                 order: 0,
                 evaluation_cost: nil,
                 metrics_data: [
                   %MetricData{name: "M", score: 1.0, success: false, strict_mode: false}
                 ]
               },
               %TestRun.TestCase{name: "b", success: true, metrics_data: [], order: 1}
             ] = test_run.test_cases

      assert test_run.metrics_scores == [
               %{metric: "M", scores: [1.0], passes: 0, fails: 1, errors: 0}
             ]

      assert test_run.test_passed == 1
      assert test_run.test_failed == 1
      assert test_run.run_duration == 0.0
      assert test_run.evaluation_cost == nil
      assert test_run.identifier == nil
      assert test_run.hyperparameters == nil
    end

    test "loads an empty object as an empty run" do
      assert from_map!(%{}) == %TestRun{}
    end

    test "ignores unknown keys, like deepeval's extra=\"ignore\"" do
      test_run =
        from_map!(%{
          "testFile" => "test_x.py",
          "datasetAlias" => "golden",
          "conversationalTestCases" => [%{"name" => "conv"}],
          "prompts" => [%{"alias" => "p"}],
          "official" => true,
          "testCases" => [
            %{
              "name" => "a",
              "trace" => %{"uuid" => "1"},
              "metricsData" => [%{"name" => "M", "verboseLogs" => "...", "success" => true}]
            }
          ]
        })

      json = encode(test_run)

      refute json =~ "testFile"
      refute json =~ "verboseLogs"
      refute json =~ "trace"
      assert json =~ ~s("conversationalTestCases": [])
      assert json =~ ~s("official": false)
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
    test "returns DeepEvalEx test cases and results, like evaluate_batch/3" do
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

    test "defaults missing tool call lists to empty lists" do
      {[test_case], _results} =
        TestRun.to_results(from_map!(%{"testCases" => [%{"name" => "a", "input" => "q"}]}))

      assert test_case.tools_called == []
      assert test_case.expected_tools == []
    end
  end
end
