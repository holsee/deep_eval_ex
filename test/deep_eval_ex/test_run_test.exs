defmodule DeepEvalEx.TestRunTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.{ExactMatch, GEval}
  alias DeepEvalEx.{Result, TestCase, TestRun}
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestRun.JSON

  defp ok(metric, score, opts \\ []) do
    Result.new([metric: metric, score: score, threshold: 0.5] ++ opts)
  end

  defp encode(test_run), do: test_run |> TestRun.to_map() |> JSON.encode!()

  describe "from_results/3 matches deepeval's export" do
    # Produced by deepeval 4.3.1's `evaluate(..., hyperparameters=...,
    # identifier="my-run", display_config=DisplayConfig(results_folder=...))`
    # with three fixed-score metrics (the third raising "boom") and
    # `ErrorConfig(ignore_errors=True)`. deepeval records per-test-case
    # durations under one second as 0.0.
    @deepeval_export ~S({"testCases": [{"name": "test_case_0", "input": "What is 1+1? caf\u00e9", "actualOutput": "2", "expectedOutput": "2", "context": ["c"], "retrievalContext": ["ctx a", "ctx b"], "toolsCalled": [{"name": "calc", "type": "FUNCTION", "output": 2, "inputParameters": {"a": 1, "b": 1.5}}], "expectedTools": [{"name": "calc", "type": "FUNCTION", "description": "d", "reasoning": "r"}], "tokenCost": 0.25, "inputTokenCount": 10, "outputTokenCount": 3, "completionTime": 1.0, "tags": ["t1"], "flaky": false, "success": false, "metricsData": [{"name": "M1", "threshold": 0.5, "success": true, "score": 1.0, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationModel": "gpt-4o", "evaluationCost": 0.001}, {"name": "M2", "threshold": 0.5, "success": false, "score": 0.25, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationCost": 0.002}, {"name": "M3", "threshold": 0.5, "success": false, "strictMode": false, "flaky": false, "error": "boom"}], "runDuration": 0.0, "evaluationCost": 0.003, "order": 0, "metadata": {"k": [1, 2.0, null, true]}, "comments": "cm"}, {"name": "named case", "input": "Q2", "actualOutput": "A2", "flaky": false, "success": false, "metricsData": [{"name": "M1", "threshold": 0.5, "success": true, "score": 1.0, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationModel": "gpt-4o", "evaluationCost": 0.001}, {"name": "M2", "threshold": 0.5, "success": false, "score": 0.25, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationCost": 0.002}, {"name": "M3", "threshold": 0.5, "success": false, "strictMode": false, "flaky": false, "error": "boom"}], "runDuration": 0.0, "evaluationCost": 0.003, "order": 1}], "conversationalTestCases": [], "metricsScores": [{"metric": "M1", "scores": [1.0, 1.0], "passes": 2, "fails": 0, "errors": 0}, {"metric": "M2", "scores": [0.25, 0.25], "passes": 0, "fails": 2, "errors": 0}, {"metric": "M3", "scores": [], "passes": 0, "fails": 0, "errors": 2}], "identifier": "my-run", "hyperparameters": {"model": "gpt-4o", "temperature": "0.7", "k": "5"}, "prompts": [], "testPassed": 0, "testFailed": 2, "runDuration": 0.009065957999609964, "evaluationCost": 0.006, "official": false})

    test "encodes the same run byte for byte" do
      test_cases = [
        %TestCase{
          input: "What is 1+1? café",
          actual_output: "2",
          expected_output: "2",
          retrieval_context: ["ctx a", "ctx b"],
          context: ["c"],
          tools_called: [
            %ToolCall{name: "calc", input_parameters: %{"a" => 1, "b" => 1.5}, output: 2}
          ],
          expected_tools: [%ToolCall{name: "calc", description: "d", reasoning: "r"}],
          tags: ["t1"],
          metadata: %{"k" => [1, 2.0, nil, true]},
          comments: "cm",
          token_cost: 0.25,
          input_token_count: 10,
          output_token_count: 3,
          completion_time: 1
        },
        %TestCase{input: "Q2", actual_output: "A2", name: "named case"}
      ]

      results = [
        ok("M1", 1.0,
          reason: "because é ✓",
          evaluation_model: "gpt-4o",
          evaluation_cost: 0.001
        ),
        ok("M2", 0.25, reason: "because é ✓", evaluation_cost: 0.002),
        Result.error("M3", "boom", threshold: 0.5)
      ]

      test_run =
        TestRun.from_results(test_cases, [results, results],
          identifier: "my-run",
          hyperparameters: [model: "gpt-4o", temperature: 0.7, k: 5],
          run_durations: [0.2, 0.3],
          run_duration: 0.009065957999609964
        )

      assert encode(test_run) == @deepeval_export
    end
  end

  describe "from_results/3 aggregates" do
    test "names unnamed test cases test_case_<order> and keeps given names" do
      test_cases = [
        %TestCase{input: "a"},
        %TestCase{input: "b", name: "mine"},
        %TestCase{input: "c"}
      ]

      results = List.duplicate([ok("M", 1.0)], 3)
      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order}) ==
               [{"test_case_0", 0}, {"mine", 1}, {"test_case_2", 2}]
    end

    test "counts passed and failed test cases" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}, %TestCase{input: "c"}]

      results = [
        [ok("M", 1.0), ok("N", 0.9)],
        [ok("M", 1.0), ok("N", 0.1)],
        [Result.error("M", "boom"), ok("N", 0.9)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, & &1.success) == [true, false, false]
      assert test_run.test_passed == 1
      assert test_run.test_failed == 2
    end

    test "aggregates scores, passes, fails and errors per metric in first-seen order" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]

      results = [
        [ok("N", 0.25), ok("M", 1.0)],
        [ok("N", 0.75), Result.error("M", "boom", threshold: 0.5)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert test_run.metrics_scores == [
               %{metric: "N", scores: [0.25, 0.75], passes: 1, fails: 1, errors: 0},
               %{metric: "M", scores: [1.0], passes: 1, fails: 0, errors: 1}
             ]
    end

    test "sums evaluation costs per test case and for the run" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}, %TestCase{input: "c"}]

      results = [
        [ok("M", 1.0, evaluation_cost: 0.1), ok("N", 1.0, evaluation_cost: 0.2)],
        [ok("M", 1.0, evaluation_cost: 0.5), ok("N", 1.0)],
        [ok("M", 1.0), ok("N", 1.0)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, & &1.evaluation_cost) == [0.1 + 0.2, 0.5, nil]
      assert test_run.evaluation_cost == 0.1 + 0.2 + 0.5
    end

    test "leaves the run's evaluation cost unset when nothing was priced" do
      test_run = TestRun.from_results([%TestCase{input: "a"}], [[ok("M", 1.0)]])

      assert test_run.evaluation_cost == nil
      refute encode(test_run) =~ "evaluationCost"
    end

    test "skips test cases without results, like deepeval" do
      test_run =
        TestRun.from_results([%TestCase{input: "a"}, %TestCase{input: "b"}], [[], [ok("M", 1.0)]])

      assert [%TestRun.TestCase{name: "test_case_1", order: 1}] = test_run.test_cases
    end

    test "records test case durations under one second as 0.0, like deepeval" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]
      results = [[ok("M", 1.0)], [ok("M", 1.0)]]

      test_run =
        TestRun.from_results(test_cases, results, run_durations: [0.999, 1.25], run_duration: 2)

      assert Enum.map(test_run.test_cases, & &1.run_duration) == [0.0, 1.25]
      assert test_run.run_duration == 2.0
    end

    test "takes strict mode from the metrics" do
      metric =
        GEval.new(
          name: "C",
          criteria: "c",
          evaluation_params: [:actual_output],
          strict_mode: true
        )

      test_run =
        TestRun.from_results([%TestCase{input: "a"}], [[ok("C [GEval]", 1.0), ok("Exact", 1.0)]],
          metrics: [metric, ExactMatch]
        )

      assert [%{metrics_data: [%{strict_mode: true}, %{strict_mode: false}]}] =
               test_run.test_cases
    end
  end

  describe "to_map/1" do
    test "omits nil fields and keeps false and zero values" do
      test_run =
        TestRun.from_results([%TestCase{input: "a"}], [[ok("M", 0.0)]], run_duration: 0)

      assert encode(test_run) ==
               ~s({"testCases": [{"name": "test_case_0", "input": "a", "flaky": false, ) <>
                 ~s("success": false, "metricsData": [{"name": "M", "threshold": 0.5, ) <>
                 ~s("success": false, "score": 0.0, "strictMode": false, "flaky": false}], ) <>
                 ~s("runDuration": 0.0, "order": 0}], "conversationalTestCases": [], ) <>
                 ~s("metricsScores": [{"metric": "M", "scores": [0.0], "passes": 0, ) <>
                 ~s("fails": 1, "errors": 0}], "prompts": [], "testPassed": 0, ) <>
                 ~s("testFailed": 1, "runDuration": 0.0, "official": false})
    end

    test "omits empty tool call and retrieval context lists but keeps an empty context" do
      test_case = %TestCase{input: "a", context: [], retrieval_context: [], tools_called: []}
      map = [test_case] |> TestRun.from_results([[ok("M", 1.0)]]) |> TestRun.to_map()

      [case_map] = get(map, "testCases")
      keys = Enum.map(case_map.values, &elem(&1, 0))

      assert "context" in keys
      refute "retrievalContext" in keys
      refute "toolsCalled" in keys
      refute "expectedTools" in keys
    end

    test "serialises tool calls like deepeval's ToolCall" do
      tool = %ToolCall{
        name: "search",
        type: :mcp,
        description: "d",
        reasoning: "r",
        output: nil,
        input_parameters: %{"q" => nil}
      }

      map =
        [%TestCase{input: "a", tools_called: [tool]}]
        |> TestRun.from_results([[ok("M", 1.0)]])
        |> TestRun.to_map()

      [case_map] = get(map, "testCases")
      [tool_map] = get(case_map, "toolsCalled")

      assert JSON.encode!(tool_map) ==
               ~s({"name": "search", "type": "MCP", "description": "d", "reasoning": "r", ) <>
                 ~s("inputParameters": {"q": null}})
    end

    test "casts integer scores, thresholds and costs to floats" do
      result = %Result{metric: "M", score: 1, success: true, threshold: 1, evaluation_cost: 0}
      json = [%TestCase{input: "a"}] |> TestRun.from_results([[result]]) |> encode()

      assert json =~ ~s("threshold": 1.0, "success": true, "score": 1.0)
      assert json =~ ~s("evaluationCost": 0.0)
      assert json =~ ~s("scores": [1.0])
    end
  end

  describe "hyperparameters" do
    test "stringifies values like deepeval and drops nil values" do
      test_run =
        TestRun.from_results([%TestCase{input: "a"}], [[ok("M", 1.0)]],
          hyperparameters: [model: "gpt-4o", temperature: 1.0, k: 5, flag: true, skip: nil]
        )

      assert test_run.hyperparameters ==
               [{"model", "gpt-4o"}, {"temperature", "1.0"}, {"k", "5"}, {"flag", "True"}]
    end

    test "accepts maps with string keys" do
      test_run =
        TestRun.from_results([%TestCase{input: "a"}], [[ok("M", 1.0)]],
          hyperparameters: %{"model" => "gpt-4o"}
        )

      assert test_run.hyperparameters == [{"model", "gpt-4o"}]
    end

    test "rejects values deepeval does not accept" do
      assert_raise ArgumentError, ~r/hyperparameter "model"/, fn ->
        TestRun.process_hyperparameters(model: {:openai, "gpt-4o"})
      end
    end
  end

  defp get(%Jason.OrderedObject{} = object, key), do: object[key]
end
