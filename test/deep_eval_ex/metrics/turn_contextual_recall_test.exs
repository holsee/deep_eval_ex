defmodule DeepEvalEx.Metrics.TurnContextualRecallTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.TurnContextualRecall
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.EvalSpec

  @outcome "Order 42 shipped on 1 October. Refunds take 5 days."

  @turns [
    %{role: :user, content: "Where is order 42?"},
    %{
      role: :assistant,
      content: "It shipped on 1 October.",
      retrieval_context: ["Order 42 shipped on 1 October."]
    }
  ]

  defp test_case(turns \\ @turns, outcome \\ @outcome),
    do: ConversationalTestCase.new!(turns: turns, expected_outcome: outcome)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TurnContextualRecall.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert TurnContextualRecall.metric_name() == "Turn Contextual Recall"

      assert TurnContextualRecall.required_params() ==
               [:role, :content, :retrieval_context, :expected_outcome]
    end
  end

  describe "measure/2" do
    test "scores the share of sentences each window's context supports" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [
                   %{
                     "verdicts" => [
                       %{"verdict" => "yes", "reason" => "The 1st node."},
                       %{"verdict" => "no", "reason" => "No refunds."}
                     ]
                   }
                 ],
                 "reason" => [%{"reason" => "Half."}, %{"reason" => "The score is 0.5."}]
               })

      assert result.metric == "Turn Contextual Recall"
      assert result.score === 0.5

      [verdicts_prompt] = prompts("verdicts")
      assert verdicts_prompt =~ "Assistant Output:\n#{@outcome}\n\nRetrieval Context:\n['Order 42"

      [window_reason, final] = prompts("reason")

      assert window_reason =~
               "Supportive Reasons:\n['The 1st node.']\n\nUnsupportive Reasons:\n['No refunds.']\n"

      assert final =~ "Final Score: 0.5\n\nReasons: \n['Half.']\n\nSuccess: True\n"
    end

    test "requires an expected outcome, as deepeval does" do
      assert {:error, {:missing_conversational_param, :expected_outcome}} =
               measure(test_case(@turns, nil), %{})
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about the turns and the expected outcome" do
      assert %EvalSpec{
               evaluation_params: [:role, :content, :retrieval_context, :expected_outcome]
             } =
               TurnContextualRecall.system_one_eval_spec(test_case(), [])
    end

    test "hybrid asks one Noul per sentence of the expected outcome about the window's context" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      assert {:ok, result} =
               measure(test_case(), %{"reason" => [%{"reason" => "a"}, %{"reason" => "b"}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert [call] = SystemOneMock.calls(system_one)
      assert Enum.map(call.questions, &elem(&1, 0)) == ["sentence_0", "sentence_1"]

      assert call.state |> Jason.encode!() |> Jason.decode!() == %{
               "retrieval_context" => ["Order 42 shipped on 1 October."],
               "sentences" => ["Order 42 shipped on 1 October.", "Refunds take 5 days."]
             }
    end

    test "a multimodal conversation is judged by the LLM in hybrid mode" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      multimodal =
        test_case([
          %{role: :user, content: "What is this? [DEEPEVAL:IMAGE:img-1]"},
          %{role: :assistant, content: "A bike.", retrieval_context: ["A red bike."]}
        ])

      assert TurnContextualRecall.system_one_eval_spec(multimodal, []) == nil

      assert {:ok, result} =
               measure(
                 multimodal,
                 %{
                   "verdicts" => [%{"verdicts" => [%{"verdict" => "yes", "reason" => "1st."}]}],
                   "reason" => [%{"reason" => "a"}, %{"reason" => "b"}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert SystemOneMock.calls(system_one) == []
      [verdicts_prompt] = prompts("verdicts")
      assert verdicts_prompt =~ "For EACH sentence and image"
      assert verdicts_prompt =~ "['Node 1: A red bike.']"
    end
  end
end
