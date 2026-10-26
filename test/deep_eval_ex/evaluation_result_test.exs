defmodule DeepEvalEx.EvaluationResultTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{EvaluationResult, Result, TestCase, TestResult}

  defp test_case(fields \\ []) do
    TestCase.new!(
      Keyword.merge(
        [
          input: "What is the capital of France?",
          actual_output: "Paris",
          expected_output: "Paris",
          context: ["France's capital is Paris."],
          retrieval_context: ["Paris is the capital of France."],
          metadata: %{"source" => "geo"}
        ],
        fields
      )
    )
  end

  defp passed(name \\ "A", opts \\ []),
    do: Result.new(Keyword.merge([metric: name, score: 1.0, threshold: 0.5], opts))

  defp failed(name \\ "B", opts \\ []),
    do: Result.new(Keyword.merge([metric: name, score: 0.0, threshold: 0.5], opts))

  describe "TestResult.new/4" do
    test "carries the test case's fields like deepeval's create_test_result" do
      result = passed()

      assert %TestResult{
               name: "test_case_3",
               success: true,
               metrics_data: [^result],
               conversational: false,
               index: 3,
               input: "What is the capital of France?",
               actual_output: "Paris",
               expected_output: "Paris",
               context: ["France's capital is Paris."],
               retrieval_context: ["Paris is the capital of France."],
               metadata: %{"source" => "geo"},
               classifications: [],
               turns: nil
             } = TestResult.new(test_case(), [result], 3)
    end

    test "keeps the test case's own name" do
      assert %TestResult{name: "capital"} = TestResult.new(test_case(name: "capital"), [], 0)
    end

    test "takes the name and index from the dataset rank, as deepeval's order" do
      test_case = %{test_case() | dataset_rank: 4}
      assert %TestResult{name: "test_case_4", index: 4} = TestResult.new(test_case, [], 1)
    end

    test "fails when a non-flaky metric failed, as deepeval's update_metric_data" do
      assert TestResult.new(test_case(), [passed(), failed()], 0).success == false
      assert TestResult.new(test_case(), [passed(), failed("B", flaky: true)], 0).success
    end

    test "score-only results neither pass nor fail the test case" do
      score_only = Result.new(metric: "S", score: 0.2, threshold: nil)

      assert score_only.success == nil
      assert TestResult.new(test_case(), [passed(), score_only], 0).success == true
    end

    test "leaves skipped results out of metrics_data, as deepeval does" do
      skipped = Result.skipped("Skipped", threshold: 0.5)

      assert %TestResult{metrics_data: [%Result{metric: "A"}], success: true} =
               TestResult.new(test_case(), [skipped, passed()], 0)
    end

    test "builds a conversational test case's result, as deepeval's conversational TestResult" do
      conversation =
        DeepEvalEx.ConversationalTestCase.new!(
          turns: [%{role: :user, content: "Hi"}],
          metadata: %{"k" => "v"}
        )

      assert %TestResult{
               name: "conversational_test_case_2",
               conversational: true,
               index: 2,
               success: false,
               input: nil,
               metadata: %{"k" => "v"}
             } = TestResult.new(conversation, [failed()], 2)
    end

    test "carries a conversation's turns as deepeval's TurnApi, for the console report" do
      conversation =
        DeepEvalEx.ConversationalTestCase.new!(
          turns: [
            %{role: :user, content: "Hi"},
            %{role: :assistant, content: "Hello", retrieval_context: []}
          ]
        )

      assert %TestResult{
               turns: [
                 %DeepEvalEx.TestRun.Turn{role: "user", content: "Hi", order: 0},
                 %DeepEvalEx.TestRun.Turn{
                   role: "assistant",
                   content: "Hello",
                   order: 1,
                   retrieval_context: nil
                 }
               ]
             } = TestResult.new(conversation, [passed()], 0)
    end

    test "without classifications, a test case no metric ran on is successful" do
      assert %TestResult{metrics_data: [], success: true} = TestResult.new(test_case(), [], 0)
    end
  end

  describe "TestResult.new/4 with classifications (deepeval's _local_success)" do
    test "a failed classification fails the test case" do
      result = TestResult.new(test_case(), [passed()], 0, [%{name: "C", success: false}])

      assert result.success == false
      assert result.classifications == [%{name: "C", success: false}]
    end

    test "a classification without a verdict leaves the metrics' verdict" do
      assert TestResult.new(test_case(), [failed()], 0, [%{success: nil}]).success == false
      assert TestResult.new(test_case(), [passed()], 0, [%{success: nil}]).success == true
    end

    test "with no metric data, classifications alone decide, and none means no verdict" do
      assert TestResult.new(test_case(), [], 0, [%{success: nil}]).success == nil
      assert TestResult.new(test_case(), [], 0, [%{success: nil}, %{success: true}]).success

      assert TestResult.new(test_case(), [], 0, [%{success: true}, %{success: false}]).success ==
               false
    end
  end

  describe "EvaluationResult.from_results/2" do
    test "builds one test result per test case, indexed by position" do
      cases = [test_case(), test_case(name: "second")]

      assert %EvaluationResult{
               test_results: [
                 %TestResult{index: 0, name: "test_case_0", success: true},
                 %TestResult{index: 1, name: "second", success: false}
               ],
               confident_link: nil,
               test_run_id: nil
             } = EvaluationResult.from_results(cases, [[passed()], [failed()]])
    end
  end
end
