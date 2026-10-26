defmodule DeepEvalEx.Metrics.ExpectationsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, Result, TestCase, TestRun}
  alias DeepEvalEx.Dataset.{EvaluationDataset, Expectations, Golden}
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Metrics.Expectations, as: ExpectationEvaluator
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.TestRun.{ExpectationsData, JSON}

  @moduletag :tmp_dir
  # evaluate_run/3 logs where it saved the test run.
  @moduletag :capture_log

  doctest DeepEvalEx.TestRun.ExpectationsData

  defp verdicts(statuses) do
    %{
      "verdicts" =>
        Enum.map(statuses, fn {id, status} ->
          %{"id" => id, "status" => status, "reason" => "Because #{id}.", "evidence" => ""}
        end)
    }
  end

  defp judge(statuses, reason \\ "The score is 1.0 because it holds.") do
    LLMMock.script(
      %{"verdicts" => [verdicts(statuses)], "reason" => [%{"reason" => reason}]},
      model: "judge"
    )
  end

  defp test_case(attrs) do
    TestCase.new!(
      [input: "Can I get a refund?", actual_output: "No, but you can exchange it."] ++ attrs
    )
  end

  defp with_expectations(attrs \\ []),
    do: test_case([expectations: %{must: ["Offers an exchange"]}] ++ attrs)

  describe "Dataset.Expectations.present?/1" do
    test "is deepeval's Expectations.__bool__: a must or must_not condition" do
      refute Expectations.present?(nil)
      refute Expectations.present?(%{model: nil, eval_mode: nil, must: [], must_not: []})
      assert Expectations.present?(%{model: nil, eval_mode: nil, must: [], must_not: ["x"]})
      assert Expectations.present?(%{model: nil, eval_mode: :llm, must: ["x"], must_not: []})
    end
  end

  describe "Dataset.Expectations.evidence/1" do
    test "dumps a test case's observed fields in deepeval's order, without nils" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          expected_output: "left out",
          retrieval_context: ["r", %RetrievedContextData{context: "x", source: "s"}],
          tools_called: [%ToolCall{name: "t", input_parameters: %{"b" => 1}}],
          metadata: %{"k" => nil},
          tags: ["t"],
          comments: "left out"
        )

      assert JSON.encode!(Expectations.evidence(test_case)) ==
               ~s({"input": "Q", "actual_output": "A", "retrieval_context": ["r", "s: x"], ) <>
                 ~s("metadata": {"k": null}, "tools_called": [{"name": "t", "type": "FUNCTION", ) <>
                 ~s("input_parameters": {"b": 1}}], "tags": ["t"]})
    end

    test "dumps a conversation's turns and fields" do
      test_case =
        ConversationalTestCase.new!(
          name: "left out",
          scenario: "S",
          chatbot_role: "Bot",
          expected_outcome: "left out",
          turns: [%{role: :user, content: "Hi"}, %{role: :assistant, content: "Hello"}]
        )

      assert JSON.encode!(Expectations.evidence(test_case)) ==
               ~s({"turns": [{"role": "user", "content": "Hi"}, ) <>
                 ~s({"role": "assistant", "content": "Hello"}], "scenario": "S", ) <>
                 ~s("chatbot_role": "Bot"})
    end
  end

  describe "the evaluator" do
    test "is injected after the metrics, only for test cases with expectations" do
      judge([{"must[0]", "pass"}])

      [[exact], [exact_too, expectations]] =
        Evaluator.evaluate(
          [test_case(expected_output: "x"), with_expectations(expected_output: "x")],
          [ExactMatch],
          adapter: :mock
        )

      assert exact.metric == "Exact Match"
      assert exact_too.metric == "Exact Match"
      assert %Result{metric: "Expectations", score: 1.0, success: true} = expectations
      assert expectations.threshold == 1
      assert expectations.strict_mode
      refute expectations.flaky

      assert %ExpectationsData{success: true, score: 1.0, verdicts: [verdict]} =
               expectations.expectations_data

      assert verdict.kind == "MUST"
      assert verdict.condition == "Offers an exchange"
    end

    test "keeps its threshold, strict mode and flakiness whatever the run sets" do
      judge([{"must[0]", "fail"}])

      [[result]] =
        Evaluator.evaluate([with_expectations()], [],
          adapter: :mock,
          threshold: 0.0,
          strict_mode: false,
          flaky: true
        )

      assert {result.score, result.success, result.threshold} == {0.0, false, 1}
      assert {result.strict_mode, result.flaky} == {true, false}
    end

    test "judges with the expectations' model and eval mode over the run's" do
      mock =
        Mock.from_fixture(%{
          "model" => "fake-jev",
          "answers" => %{
            "choices" => %{
              "q_0" => %{
                "choice" => "pass",
                "probabilities" => %{"pass" => 0.9, "fail" => 0.1, "unable_to_evaluate" => 0.0},
                "confidence" => 0.8
              }
            }
          }
        })

      test_case =
        test_case(expectations: %{must: ["Offers an exchange"], eval_mode: "system_one"})

      [[result]] =
        Evaluator.evaluate([test_case], [], eval_mode: :llm, system_one_model: mock)

      assert result.evaluation_model == "fake-jev"
      assert result.success
      assert [_call] = Mock.dump_calls(mock)
    end

    test "has criteria that tell its eval modes and System One models apart" do
      mock = Mock.from_fixture(%{"model" => "fake-jev", "answers" => %{}})

      llm =
        ExpectationEvaluator.new(%{model: nil, eval_mode: :llm, must: ["x"], must_not: []}, [])

      system_one =
        ExpectationEvaluator.new(
          %{model: nil, eval_mode: :system_one, must: ["x"], must_not: []},
          []
        )

      assert ExpectationEvaluator.criteria(llm, []) ==
               ~s({"eval_mode": "llm", "system_one_model": null})

      assert ExpectationEvaluator.criteria(system_one, system_one_model: mock) ==
               ~s({"eval_mode": "system_one", "system_one_model": "fake-jev"})

      # hybrid has no extraction to keep: it runs as llm.
      hybrid =
        ExpectationEvaluator.new(%{model: nil, eval_mode: nil, must: ["x"], must_not: []}, [])

      assert ExpectationEvaluator.new(hybrid.expectations, eval_mode: :hybrid).eval_mode == :llm
    end
  end

  describe "the test run" do
    test "carries expectationsData, without an Expectations row or score", %{tmp_dir: tmp_dir} do
      judge([{"must[0]", "fail"}], "The score is 0.0 because it refuses.")

      {[[_exact, result]], test_run, path} =
        DeepEvalEx.evaluate_run([with_expectations(expected_output: "x")], [ExactMatch],
          adapter: :mock,
          results_folder: tmp_dir
        )

      assert result.metric == "Expectations"
      [api_test_case] = test_run.test_cases
      # It fails the test case as a metric would.
      assert api_test_case.success == false
      assert test_run.test_failed == 1
      assert Enum.map(test_run.metrics_scores, & &1.metric) == ["Exact Match"]

      [exported] = path |> File.read!() |> Jason.decode!() |> Map.fetch!("testCases")
      assert Enum.map(exported["metricsData"], & &1["name"]) == ["Exact Match"]

      assert exported["expectationsData"] == %{
               "success" => false,
               "score" => 0.0,
               "reason" => "The score is 0.0 because it refuses.",
               "verdicts" => [
                 %{
                   "kind" => "MUST",
                   "condition" => "Offers an exchange",
                   "status" => "fail",
                   "reason" => "Because must[0].",
                   "evidence" => ""
                 }
               ],
               "evaluationModel" => "judge"
             }
    end

    test "is written for expectations alone", %{tmp_dir: tmp_dir} do
      judge([{"must[0]", "pass"}])

      {:ok, %{test_results: [test_result]}} =
        DeepEvalEx.evaluate([with_expectations()], [], adapter: :mock, results_folder: tmp_dir)

      assert test_result.success
      assert test_result.expectations.must == ["Offers an exchange"]
      assert [_file] = Path.wildcard(Path.join(tmp_dir, "test_run_*.json"))
    end

    test "is written for classifiers and expectations without metrics" do
      LLMMock.script(
        %{
          "verdicts" => [verdicts([{"must[0]", "pass"}])],
          "reason" => [%{"reason" => "It offers an exchange."}],
          "label,reason" => [%{"label" => "partial_refusal", "reason" => "It declines a refund."}]
        },
        model: "judge"
      )

      {[[result]], test_run, _path} =
        DeepEvalEx.evaluate_run([with_expectations()], [],
          adapter: :mock,
          classifiers: [DeepEvalEx.Classifiers.refusal()]
        )

      assert result.metric == "Expectations"
      assert [%TestRun.TestCase{metrics_data: [], success: true}] = test_run.test_cases
    end

    test "with expectations, no metric needs a threshold" do
      judge([{"must[0]", "pass"}])

      {:ok, %{test_results: [test_result]}} =
        DeepEvalEx.evaluate([with_expectations(expected_output: "x")], [ExactMatch],
          adapter: :mock,
          threshold: nil
        )

      assert test_result.success
    end
  end

  test "a dataset's goldens carry their expectations to the evaluator" do
    judge([{"must[0]", "pass"}])

    dataset = EvaluationDataset.new([Golden.new!(input: "Hi", expectations: %{must: ["Greets"]})])

    {[test_case], [[result]], test_run, _path} =
      EvaluationDataset.evaluate_run(dataset, fn _golden -> "Hello!" end, [], adapter: :mock)

    assert test_case.expectations.must == ["Greets"]
    assert result.metric == "Expectations"
    assert [%TestRun.TestCase{expectations_data: %Jason.OrderedObject{}}] = test_run.test_cases
  end
end

defmodule DeepEvalEx.Metrics.ExpectationsSettingTest do
  # Changes the :eval_mode application setting.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Metrics.Expectations

  setup do
    previous = Application.fetch_env(:deep_eval_ex, :eval_mode)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:deep_eval_ex, :eval_mode, value)
        :error -> Application.delete_env(:deep_eval_ex, :eval_mode)
      end
    end)
  end

  test "the eval mode setting wins over the expectations' own, as deepeval's" do
    Application.put_env(:deep_eval_ex, :eval_mode, :llm)
    expectations = %{model: nil, eval_mode: :system_one, must: ["x"], must_not: []}
    assert Expectations.new(expectations, []).eval_mode == :llm

    Application.put_env(:deep_eval_ex, :eval_mode, :hybrid)
    assert Expectations.new(expectations, []).eval_mode == :llm
  end
end
