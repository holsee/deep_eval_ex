defmodule DeepEvalEx.Metrics.TurnContextualPrecisionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.TurnContextualPrecision
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}

  @outcome "The assistant says order 42 shipped on 1 October."

  @turns [
    %{role: :user, content: "Where is order 42?"},
    %{
      role: :assistant,
      content: "It shipped on 1 October.",
      retrieval_context: ["Rome is in Italy.", "Order 42 shipped on 1 October."]
    },
    %{role: :user, content: "Thanks."},
    %{role: :assistant, content: "You're welcome!"}
  ]

  defp test_case(turns \\ @turns, outcome \\ @outcome),
    do: ConversationalTestCase.new!(turns: turns, expected_outcome: outcome)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TurnContextualPrecision.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  @verdicts %{
    "verdicts" => [
      %{"verdict" => "no", "reason" => "Rome is irrelevant."},
      %{"verdict" => "yes", "reason" => "It gives the date."}
    ]
  }

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert TurnContextualPrecision.metric_name() == "Turn Contextual Precision"

      assert TurnContextualPrecision.required_params() ==
               [:role, :content, :retrieval_context, :expected_outcome]
    end
  end

  describe "measure/2" do
    test "scores each window's ranking and averages the windows" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [@verdicts, @verdicts],
                 "reason" => [
                   %{"reason" => "Rome first."},
                   %{"reason" => "Rome first again."},
                   %{"reason" => "The score is 0.5."}
                 ]
               })

      assert result.metric == "Turn Contextual Precision"
      assert result.score === 0.5
      assert result.reason == "The score is 0.5."

      [first, _second] = prompts("verdicts")
      assert first =~ "User Message:\n\nWhere is order 42? \n\nAssistant Output:\n#{@outcome}\n"
      assert first =~ "Retrieval Context  (2 documents):\n['Rome is in Italy.', 'Order 42"

      [first, _second, _final] = prompts("reason")
      assert first =~ "Contextual Precision Score:\n0.50\n"

      assert first =~
               "[{'verdict': <Verdict.NO: 'no'>, 'reason': 'Rome is irrelevant.', 'node': 'Node 1'}"
    end

    test "scores a window without retrieval context 1.0, explained without the judge" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{"verdicts" => [@verdicts], "reason" => [%{"reason" => "Rome first."}]},
                 window_size: 1,
                 include_reason: false
               )

      assert result.score === 0.75
      assert result.reason == nil

      assert [_first, %{score: 1.0, reason: "There were no retrieval contexts" <> _}] =
               result.metadata.windows
    end

    test "clamps each window's score to 0 in strict mode, never the mean" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "verdicts" => [@verdicts],
                   "reason" => [%{"reason" => "Rome first."}, %{"reason" => "Strict."}]
                 },
                 strict_mode: true,
                 window_size: 1
               )

      assert result.score === 0.5
      [window_reason, _final] = prompts("reason")
      assert window_reason =~ "Contextual Precision Score:\n0.00\n"
    end

    test "requires an expected outcome, as deepeval does" do
      assert {:error, {:missing_conversational_param, :expected_outcome}} =
               measure(test_case(@turns, nil), %{})
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about the turns and the expected outcome" do
      assert %EvalSpec{
               evaluation_params: [:role, :content, :retrieval_context, :expected_outcome],
               questions: [%Scored.Noul{weight: 2.0}, %Scored.Noul{}, %Scored.Score{}]
             } = TurnContextualPrecision.system_one_eval_spec(test_case(), [])
    end

    test "hybrid asks one Noul per node about the user message and the expected outcome" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.8))

      assert {:ok, result} =
               measure(
                 test_case(Enum.take(@turns, 2)),
                 %{"reason" => [%{"reason" => "a"}, %{"reason" => "b"}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert prompts("verdicts") == []
      assert [call] = SystemOneMock.calls(system_one)
      assert Enum.map(call.questions, &elem(&1, 0)) == ["node_0", "node_1"]

      assert call.state |> Jason.encode!() |> Jason.decode!() == %{
               "user_message" => "\nWhere is order 42? ",
               "assistant_output" => @outcome,
               "nodes" => ["Rome is in Italy.", "Order 42 shipped on 1 October."]
             }
    end
  end
end
