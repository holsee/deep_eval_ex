defmodule DeepEvalEx.TestRunTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Result, TestCase, TestRun}
  alias DeepEvalEx.Metrics.ArgumentCorrectness
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestRun.JSON

  defp ok(metric, score, opts \\ []) do
    Result.new(Keyword.merge([metric: metric, score: score, threshold: 0.5], opts))
  end

  defp encode(test_run), do: test_run |> TestRun.to_map() |> JSON.encode!()

  describe "from_results/3 matches deepeval's export" do
    # Produced by deepeval 4.3.1's `evaluate(..., hyperparameters=...,
    # identifier="my-run", display_config=DisplayConfig(results_folder=...))`
    # with three fixed-score metrics (the third raising "boom") and
    # `ErrorConfig(ignore_errors=True)`. deepeval's async executor records
    # per-test-case durations under one second as the integer 0.
    @deepeval_export ~S({"testCases": [{"name": "test_case_0", "input": "What is 1+1? caf\u00e9", "actualOutput": "2", "expectedOutput": "2", "context": ["c"], "retrievalContext": ["ctx a", "ctx b"], "toolsCalled": [{"name": "calc", "type": "FUNCTION", "output": 2, "inputParameters": {"a": 1, "b": 1.5}}], "expectedTools": [{"name": "calc", "type": "FUNCTION", "description": "d", "reasoning": "r"}], "tokenCost": 0.25, "inputTokenCount": 10, "outputTokenCount": 3, "completionTime": 1.0, "tags": ["t1"], "flaky": false, "success": false, "metricsData": [{"name": "M1", "threshold": 0.5, "success": true, "score": 1.0, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationModel": "gpt-4o", "evaluationCost": 0.001}, {"name": "M2", "threshold": 0.5, "success": false, "score": 0.25, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationCost": 0.002}, {"name": "M3", "threshold": 0.5, "success": false, "strictMode": false, "flaky": false, "error": "boom"}], "runDuration": 0, "evaluationCost": 0.003, "order": 0, "metadata": {"k": [1, 2.0, null, true]}, "comments": "cm"}, {"name": "named case", "input": "Q2", "actualOutput": "A2", "flaky": false, "success": false, "metricsData": [{"name": "M1", "threshold": 0.5, "success": true, "score": 1.0, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationModel": "gpt-4o", "evaluationCost": 0.001}, {"name": "M2", "threshold": 0.5, "success": false, "score": 0.25, "reason": "because \u00e9 \u2713", "strictMode": false, "flaky": false, "evaluationCost": 0.002}, {"name": "M3", "threshold": 0.5, "success": false, "strictMode": false, "flaky": false, "error": "boom"}], "runDuration": 0, "evaluationCost": 0.003, "order": 1}], "conversationalTestCases": [], "metricsScores": [{"metric": "M1", "scores": [1.0, 1.0], "passes": 2, "fails": 0, "errors": 0}, {"metric": "M2", "scores": [0.25, 0.25], "passes": 0, "fails": 2, "errors": 0}, {"metric": "M3", "scores": [], "passes": 0, "fails": 0, "errors": 2}], "identifier": "my-run", "hyperparameters": {"model": "gpt-4o", "temperature": "0.7", "k": "5"}, "prompts": [], "testPassed": 0, "testFailed": 2, "runDuration": 0.009065957999609964, "evaluationCost": 0.006, "official": false})

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

    # deepeval 4.3.1's create_api_test_case takes a test case's
    # _dataset_rank as its order (and so its test_case_<order> name), and
    # sort_test_cases writes testCases sorted by order. When two datasets'
    # ranks collide, _assign_unique_orders renumbers the orders from 0 and
    # leaves the names as they were.
    test "orders and names test cases by their dataset rank, sorted by order" do
      test_cases = [
        %TestCase{input: "c", dataset_rank: 2},
        %TestCase{input: "p"},
        %TestCase{input: "a", dataset_rank: 0}
      ]

      results = List.duplicate([ok("M", 1.0)], 3)
      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order, &1.input}) ==
               [{"test_case_0", 0, "a"}, {"test_case_1", 1, "p"}, {"test_case_2", 2, "c"}]
    end

    test "renumbers duplicate orders from 0 and keeps their names, as deepeval" do
      # deepeval: [ds.test_cases[1], ds2.test_cases[0], ds.test_cases[0]]
      test_cases = [
        %TestCase{input: "b", dataset_rank: 1},
        %TestCase{input: "z", dataset_rank: 0},
        %TestCase{input: "a", dataset_rank: 0}
      ]

      results = [[ok("M", 1.0)], [ok("M", 0.5)], [ok("M", 0.0)]]
      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order, &1.input}) ==
               [{"test_case_0", 0, "z"}, {"test_case_0", 1, "a"}, {"test_case_1", 2, "b"}]

      # metricsScores are built before the sort, in the given order
      assert [%{scores: scores}] = test_run.metrics_scores
      assert scores == [1.0, 0.5, 0.0]
    end

    test "counts passed and failed test cases" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}, %TestCase{input: "c"}]

      results = [
        [ok("M", 1.0), ok("N", 0.9)],
        [ok("M", 1.0), ok("N", 0.1)],
        [Result.error("M", "boom", threshold: 0.5), ok("N", 0.9)]
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

    test "records test case durations under one second as the integer 0, like deepeval" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]
      results = [[ok("M", 1.0)], [ok("M", 1.0)]]

      test_run =
        TestRun.from_results(test_cases, results, run_durations: [0.999, 1.25], run_duration: 2)

      assert [zero, 1.25] = Enum.map(test_run.test_cases, & &1.run_duration)
      assert zero === 0
      assert test_run.run_duration == 2.0
      assert encode(test_run) =~ ~s("runDuration": 0, "order": 0})
      assert encode(test_run) =~ ~s("runDuration": 1.25, "order": 1})
    end

    test "takes strict mode and flakiness from each result" do
      results = [
        ok("C [GEval]", 1, threshold: 1, strict_mode: true),
        ok("Exact", 1.0, flaky: true)
      ]

      test_run = TestRun.from_results([%TestCase{input: "a"}], [results])

      assert [
               %{
                 metrics_data: [
                   %{strict_mode: true, flaky: false, threshold: 1},
                   %{strict_mode: false, flaky: true}
                 ]
               }
             ] = test_run.test_cases

      assert encode(test_run) =~ ~s("threshold": 1.0, "success": true, "score": 1.0)
      assert encode(test_run) =~ ~s("strictMode": true, "flaky": false)
    end

    test "exports each result's verbose logs as verboseLogs and reads them back" do
      results = [
        Result.new(metric: "Faithfulness", score: 1.0, verbose_logs: "Claims:\n[]"),
        Result.error("Hallucination", "boom", threshold: 0.5)
      ]

      test_run = TestRun.from_results([%TestCase{input: "a"}], [results])

      assert [%{metrics_data: [%{verbose_logs: "Claims:\n[]"}, %{verbose_logs: nil}]}] =
               test_run.test_cases

      json = encode(test_run)
      assert json =~ ~s("flaky": false, "verboseLogs": "Claims:\\n[]"})
      assert length(String.split(json, "verboseLogs")) == 2

      assert {_test_cases, [[%Result{verbose_logs: "Claims:\n[]"}, %Result{verbose_logs: nil}]]} =
               TestRun.to_results(test_run)
    end

    test "flaky metrics never decide a test case's success, as deepeval's update_status" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]

      results = [
        [ok("M", 0.1, flaky: true), ok("N", 0.9)],
        [Result.error("M", "boom", threshold: 0.5, flaky: true), ok("N", 0.9)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, & &1.success) == [true, true]
      assert test_run.test_passed == 2

      assert [%{metric: "M", passes: 0, fails: 1, errors: 1}, %{metric: "N", passes: 2}] =
               test_run.metrics_scores
    end

    test "score-only results neither pass nor fail, and are counted as errors like deepeval" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]

      results = [
        [ok("S", 0.25, threshold: nil), ok("N", 0.9)],
        [ok("S", 0.25, threshold: nil), ok("N", 0.1)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.test_cases, & &1.success) == [true, false]
      assert [%{metric: "S", scores: [], errors: 2} | _] = test_run.metrics_scores
      refute encode(test_run) =~ ~s("name": "S", "threshold")
      assert encode(test_run) =~ ~s({"name": "S", "score": 0.25, "strictMode": false)
    end

    test "leaves skipped results out, and test cases whose results were all skipped" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b"}]

      results = [
        [Result.skipped("Exact Match", threshold: 1), ok("N", 0.9)],
        [Result.skipped("Exact Match", threshold: 1)]
      ]

      test_run = TestRun.from_results(test_cases, results)

      assert [%TestRun.TestCase{order: 0, metrics_data: [%{name: "N"}]}] = test_run.test_cases
      assert [%{metric: "N"}] = test_run.metrics_scores
    end
  end

  describe "from_results/3 with conversational test cases" do
    defp conversation(attrs \\ []) do
      [turns: [%{role: :user, content: "Hi"}, %{role: :assistant, content: "Hello"}]]
      |> Keyword.merge(attrs)
      |> ConversationalTestCase.new!()
    end

    test "exports them as conversationalTestCases, as deepeval's ConversationalApiTestCase" do
      test_case =
        conversation(
          scenario: "s",
          expected_outcome: "o",
          user_description: "u",
          context: ["c"],
          tags: ["t"],
          metadata: %{"k" => 1},
          comments: "cm"
        )

      test_run = TestRun.from_results([test_case], [[ok("M", 0.75, evaluation_cost: 0.25)]])

      assert test_run.test_cases == []

      assert [
               %TestRun.ConversationalTestCase{
                 name: "conversational_test_case_0",
                 success: true,
                 run_duration: +0.0,
                 evaluation_cost: 0.25,
                 order: 0,
                 scenario: "s",
                 expected_outcome: "o",
                 user_description: "u",
                 context: ["c"],
                 tags: ["t"],
                 metadata: %{"k" => 1},
                 comments: "cm",
                 flaky: false,
                 turns: [
                   %TestRun.Turn{role: "user", content: "Hi", order: 0},
                   %TestRun.Turn{role: "assistant", content: "Hello", order: 1}
                 ]
               }
             ] = test_run.conversational_test_cases

      assert encode(test_run) =~
               ~s("conversationalTestCases": [{"name": "conversational_test_case_0", ) <>
                 ~s("success": true, "metricsData": [{"name": "M", "threshold": 0.5, ) <>
                 ~s("success": true, "score": 0.75, "strictMode": false, "flaky": false, ) <>
                 ~s("evaluationCost": 0.25}], "runDuration": 0.0, "evaluationCost": 0.25, ) <>
                 ~s("turns": [{"role": "user", "content": "Hi", "order": 0}, ) <>
                 ~s({"role": "assistant", "content": "Hello", "order": 1}], "order": 0, ) <>
                 ~s("scenario": "s", "expectedOutcome": "o", "userDescription": "u", ) <>
                 ~s("context": ["c"], "comments": "cm", "metadata": {"k": 1}, "tags": ["t"], ) <>
                 ~s("flaky": false}], "metricsScores": [{"metric": "M", "scores": [0.75], ) <>
                 ~s("passes": 1, "fails": 0, "errors": 0}])
    end

    test "names unnamed ones conversational_test_case_<order>, by dataset rank, sorted" do
      test_cases = [
        %{conversation() | dataset_rank: 3},
        conversation(name: "named"),
        conversation()
      ]

      results = List.duplicate([ok("M", 1.0)], 3)

      test_run = TestRun.from_results(test_cases, results)

      assert Enum.map(test_run.conversational_test_cases, &{&1.name, &1.order}) ==
               [
                 {"named", 1},
                 {"conversational_test_case_2", 2},
                 {"conversational_test_case_3", 3}
               ]
    end

    test "renumbers duplicate orders from 0, as deepeval's sort_test_cases" do
      test_cases = [%{conversation() | dataset_rank: 1}, conversation(), conversation()]

      test_run = TestRun.from_results(test_cases, List.duplicate([ok("M", 1.0)], 3))

      assert Enum.map(test_run.conversational_test_cases, &{&1.name, &1.order}) ==
               [
                 {"conversational_test_case_1", 0},
                 {"conversational_test_case_1", 1},
                 {"conversational_test_case_2", 2}
               ]
    end

    test "flattens each turn's retrieval context and leaves out an empty one" do
      test_case =
        conversation(
          turns: [
            %{
              role: :assistant,
              content: "a",
              user_id: "u-1",
              retrieval_context: ["x", %RetrievedContextData{context: "y", source: "s"}],
              tools_called: []
            },
            %{role: :assistant, content: "b", retrieval_context: []}
          ]
        )

      [conversational] =
        TestRun.from_results([test_case], [[ok("M", 1.0)]]).conversational_test_cases

      assert [
               %TestRun.Turn{retrieval_context: ["x", "y"], tools_called: [], user_id: nil},
               %TestRun.Turn{retrieval_context: nil, tools_called: nil}
             ] = conversational.turns
    end

    test "never exports a turn's user_id, as deepeval's create_api_turn" do
      # create_api_turn passes user_id by field name, which TurnApi (aliased
      # userId, without populate_by_name) ignores.
      test_case = conversation(turns: [%{role: :user, content: "Hi", user_id: "u-1"}])

      refute [test_case] |> TestRun.from_results([[ok("M", 1.0)]]) |> encode() =~ "userId"
    end

    test "records the test case's duration as a float, as deepeval sums it" do
      test_run =
        TestRun.from_results([conversation(), conversation()], [[ok("M", 1.0)], [ok("M", 1.0)]],
          run_durations: [0.25, 2]
        )

      assert Enum.map(test_run.conversational_test_cases, & &1.run_duration) == [0.25, 2.0]
      assert encode(test_run) =~ ~s("runDuration": 0.25, )
    end

    test "counts passed and failed ones and aggregates their metric scores" do
      test_run =
        TestRun.from_results(
          [conversation(), conversation(), conversation()],
          [
            [ok("M", 1.0), ok("N", 0.75, evaluation_cost: 0.5)],
            [ok("M", 0.25), Result.error("N", "boom", threshold: 0.5)],
            []
          ]
        )

      assert {test_run.test_passed, test_run.test_failed} == {1, 1}
      assert Enum.map(test_run.conversational_test_cases, & &1.success) == [true, false]
      assert test_run.evaluation_cost == 0.5

      assert test_run.metrics_scores == [
               %{metric: "M", scores: [1.0, 0.25], passes: 1, fails: 1, errors: 0},
               %{metric: "N", scores: [0.75], passes: 1, fails: 0, errors: 1}
             ]
    end

    test "flaky metrics never decide their success, as deepeval's update_metric_data" do
      [conversational] =
        TestRun.from_results([conversation()], [[ok("M", 0.0, flaky: true)]]).conversational_test_cases

      assert conversational.success
    end

    test "orders single- and multi-turn test cases separately, as deepeval's counters" do
      test_run =
        TestRun.from_results(
          [%TestCase{input: "q"}, conversation(), %TestCase{input: "r"}],
          List.duplicate([ok("M", 1.0)], 3)
        )

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order}) ==
               [{"test_case_0", 0}, {"test_case_1", 1}]

      assert Enum.map(test_run.conversational_test_cases, &{&1.name, &1.order}) ==
               [{"conversational_test_case_0", 0}]
    end

    test "to_results/1 turns them back into conversational test cases and results" do
      test_case =
        conversation(
          name: "c",
          scenario: "s",
          turns: [
            %{
              role: :user,
              content: "Hi",
              retrieval_context: [%RetrievedContextData{context: "y", source: "s"}],
              tools_called: [%ToolCall{name: "t"}]
            }
          ]
        )

      results = [[ok("M", 0.75)]]

      assert {[%ConversationalTestCase{} = loaded], [[%Result{metric: "M", score: 0.75}]]} =
               [test_case] |> TestRun.from_results(results) |> TestRun.to_results()

      assert loaded.name == "c"
      assert loaded.scenario == "s"

      assert [%DeepEvalEx.Turn{role: :user, content: "Hi", retrieval_context: ["y"]}] =
               loaded.turns

      assert [%ToolCall{name: "t"}] = hd(loaded.turns).tools_called
    end
  end

  describe "from_results/3 matches deepeval's score-only, flaky and skipped export" do
    # Produced by deepeval 4.3.1's `evaluate()` with
    # `ErrorConfig(skip_on_missing_params=True)` and three metrics: a flaky
    # `ExactMatchMetric` (skipped on the second test case, which has no
    # expected output) and two fixed-score custom metrics, one with a
    # threshold of 0.1 and one with `threshold=None`. The test cases'
    # `runDuration` is shown as the integer 0 deepeval's async executor
    # records for sub-second test cases.
    @score_only_export ~S({"testCases": [{"name": "test_case_0", "input": "a", "actualOutput": "x", "expectedOutput": "y", "flaky": false, "success": true, "metricsData": [{"name": "Exact Match", "threshold": 1.0, "success": false, "score": 0.0, "reason": "The actual and expected outputs are different.", "strictMode": false, "flaky": true}, {"name": "ScoreOnly", "threshold": 0.1, "success": true, "score": 0.25, "reason": "r", "strictMode": false, "flaky": false}, {"name": "ScoreOnly", "score": 0.25, "reason": "r", "strictMode": false, "flaky": false}], "runDuration": 0, "order": 0}, {"name": "test_case_1", "input": "b", "actualOutput": "x", "flaky": false, "success": true, "metricsData": [{"name": "ScoreOnly", "threshold": 0.1, "success": true, "score": 0.25, "reason": "r", "strictMode": false, "flaky": false}, {"name": "ScoreOnly", "score": 0.25, "reason": "r", "strictMode": false, "flaky": false}], "runDuration": 0, "order": 1}], "conversationalTestCases": [], "metricsScores": [{"metric": "Exact Match", "scores": [0.0], "passes": 0, "fails": 1, "errors": 0}, {"metric": "ScoreOnly", "scores": [0.25, 0.25], "passes": 2, "fails": 0, "errors": 2}], "prompts": [], "testPassed": 2, "testFailed": 0, "runDuration": 0.01653450000048906, "official": false})

    test "encodes the same run byte for byte" do
      test_cases = [
        %TestCase{input: "a", actual_output: "x", expected_output: "y"},
        %TestCase{input: "b", actual_output: "x"}
      ]

      score_only = [
        ok("ScoreOnly", 0.25, threshold: 0.1, reason: "r"),
        ok("ScoreOnly", 0.25, threshold: nil, reason: "r")
      ]

      exact_match =
        ok("Exact Match", 0.0,
          threshold: 1,
          reason: "The actual and expected outputs are different.",
          flaky: true
        )

      results = [
        [exact_match | score_only],
        [Result.skipped("Exact Match", threshold: 1, flaky: true) | score_only]
      ]

      test_run = TestRun.from_results(test_cases, results, run_duration: 0.01653450000048906)

      assert encode(test_run) == @score_only_export
    end

    test "loads and re-encodes the run byte for byte" do
      {:ok, test_run} =
        TestRun.from_map(Jason.decode!(@score_only_export, objects: :ordered_objects))

      assert [%{success: true, metrics_data: [_, _, %{threshold: nil, success: nil}]} | _] =
               test_run.test_cases

      assert encode(test_run) == @score_only_export
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
                 ~s("runDuration": 0, "order": 0}], "conversationalTestCases": [], ) <>
                 ~s("metricsScores": [{"metric": "M", "scores": [0.0], "passes": 0, ) <>
                 ~s("fails": 1, "errors": 0}], "prompts": [], "testPassed": 0, ) <>
                 ~s("testFailed": 1, "runDuration": 0.0, "official": false})
    end

    test "writes testFile first and the dataset keys before official, like deepeval's TestRun" do
      test_run =
        TestRun.from_results([%TestCase{input: "a"}], [[ok("M", 1.0)]],
          test_file: "test_chatbot.py",
          dataset_alias: "golden",
          dataset_id: "ds_1",
          dataset_version: "2",
          official: true
        )

      assert test_run.prompts == []

      keys = test_run |> TestRun.to_map() |> Map.fetch!(:values) |> Enum.map(&elem(&1, 0))

      assert keys ==
               ~w(testFile testCases conversationalTestCases metricsScores prompts testPassed
                  testFailed runDuration datasetAlias datasetId datasetVersion official)

      assert encode(test_run) =~
               ~s("runDuration": 0.0, "datasetAlias": "golden", "datasetId": "ds_1", ) <>
                 ~s("datasetVersion": "2", "official": true})
    end

    test "leaves out prompts a hand-built run does not set, as deepeval's exclude_none" do
      refute encode(%TestRun{}) =~ "prompts"
      assert encode(%TestRun{prompts: []}) =~ ~s("prompts": [])
    end

    test "omits an empty retrieval context list but keeps an empty context" do
      test_case = %TestCase{input: "a", context: [], retrieval_context: []}
      map = [test_case] |> TestRun.from_results([[ok("M", 1.0)]]) |> TestRun.to_map()

      [case_map] = get(map, "testCases")
      keys = Enum.map(case_map.values, &elem(&1, 0))

      assert "context" in keys
      refute "retrievalContext" in keys
    end

    test "exports only the context of RetrievedContextData, as deepeval's create_api_test_case" do
      data = %RetrievedContextData{context: "Paris is in France.", source: "wiki"}
      test_case = %TestCase{input: "a", retrieval_context: [data, "plain chunk"]}
      test_run = TestRun.from_results([test_case], [[ok("M", 1.0)]])

      assert encode(test_run) =~ ~s("retrievalContext": ["Paris is in France.", "plain chunk"])

      assert {[%{retrieval_context: ["Paris is in France.", "plain chunk"]}], _results} =
               TestRun.to_results(test_run)

      assert %{retrieval_context: ["Paris is in France.", "plain chunk"]} =
               DeepEvalEx.TestResult.new(test_case, [ok("M", 1.0)], 0)
    end

    test "keeps an empty tool call list and omits unset ones, as deepeval's exclude_none" do
      test_case = %TestCase{input: "a", tools_called: []}
      map = [test_case] |> TestRun.from_results([[ok("M", 1.0)]]) |> TestRun.to_map()

      [case_map] = get(map, "testCases")

      assert get(case_map, "toolsCalled") == []
      refute "expectedTools" in Enum.map(case_map.values, &elem(&1, 0))
    end

    test "to_results/1 keeps unset tool call lists nil and an empty one empty" do
      test_cases = [%TestCase{input: "a"}, %TestCase{input: "b", tools_called: []}]
      test_run = TestRun.from_results(test_cases, [[ok("M", 1.0)], [ok("M", 1.0)]])

      assert {[unset, empty], _results} = TestRun.to_results(test_run)

      assert %TestCase{tools_called: nil, expected_tools: nil} = unset
      assert %TestCase{tools_called: [], expected_tools: nil} = empty

      assert {:error, _missing} = ArgumentCorrectness.validate_test_case(unset)

      [unset_map, empty_map] =
        test_cases
        |> TestRun.from_results([[ok("M", 1.0)], [ok("M", 1.0)]])
        |> TestRun.to_results()
        |> then(fn {cases, results} -> TestRun.from_results(cases, results) end)
        |> TestRun.to_map()
        |> get("testCases")

      refute "toolsCalled" in Enum.map(unset_map.values, &elem(&1, 0))
      assert get(empty_map, "toolsCalled") == []
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
