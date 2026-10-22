defmodule DeepEvalEx.Metrics.TurnContextualRelevancyTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.TurnContextualRelevancy
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.EvalSpec

  @turns [
    %{role: :user, content: "Where is order 42?"},
    %{
      role: :assistant,
      content: "It shipped on 1 October.",
      retrieval_context: ["Order 42 shipped on 1 October. Rome is in Italy.", "Our café is open."]
    }
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TurnContextualRelevancy.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert TurnContextualRelevancy.metric_name() == "Turn Contextual Relevancy"
      assert TurnContextualRelevancy.required_params() == [:role, :content, :retrieval_context]
    end
  end

  describe "measure/2" do
    test "asks for each node's statements and scores the relevant share of the window" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [
                   %{
                     "verdicts" => [
                       %{"statement" => "Order 42 shipped on 1 October.", "verdict" => "yes"},
                       %{
                         "statement" => "Rome is in Italy.",
                         "verdict" => "no",
                         "reason" => "Italy."
                       }
                     ]
                   },
                   %{"verdicts" => [%{"statement" => "Our café is open.", "verdict" => "no"}]}
                 ],
                 "reason" => [%{"reason" => "A third."}, %{"reason" => "The score is 0.33."}]
               })

      assert result.metric == "Turn Contextual Relevancy"
      assert result.score === 1 / 3
      refute result.success

      [first, second] = prompts("verdicts")
      assert first =~ "Context:\nOrder 42 shipped on 1 October. Rome is in Italy.\n"
      assert second =~ "Context:\nOur café is open.\n"

      [window_reason, _final] = prompts("reason")

      assert window_reason =~
               "['Rome is in Italy.: Italy.', 'Our café is open.: None']\n\n" <>
                 "Statement in the retrieval context that is relevant to the user message:\n" <>
                 "['Order 42 shipped on 1 October.']\n"
    end

    test "judges a RetrievedContextData node as Python's str() of it" do
      turns = [
        hd(@turns),
        %{
          role: :assistant,
          content: "It shipped.",
          retrieval_context: [%RetrievedContextData{context: "It shipped.", source: "db"}]
        }
      ]

      assert {:ok, _result} =
               measure(
                 test_case(turns),
                 %{
                   "verdicts" => [
                     %{"verdicts" => [%{"statement" => "It shipped.", "verdict" => "yes"}]}
                   ]
                 },
                 include_reason: false
               )

      [prompt] = prompts("verdicts")
      assert prompt =~ "Context:\ncontext='It shipped.' source='db'\n"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about each turn's role, content and retrieval context" do
      assert %EvalSpec{evaluation_params: [:role, :content, :retrieval_context]} =
               TurnContextualRelevancy.system_one_eval_spec(test_case(), [])
    end

    test "hybrid asks one request per node, one Noul per sentence about the user message" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.3))

      assert {:ok, result} =
               measure(test_case(), %{"reason" => [%{"reason" => "a"}, %{"reason" => "b"}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0

      assert [
               %{
                 verdicts: [
                   %{statement: "Order 42 shipped on 1 October.", reason: "P(yes)=0.30"} | _
                 ]
               }
             ] =
               result.metadata.windows

      assert [first, second] = SystemOneMock.calls(system_one)
      assert Enum.map(first.questions, &elem(&1, 0)) == ["statement_0", "statement_1"]

      assert second.state |> Jason.encode!() |> Jason.decode!() == %{
               "user_message" => "\nWhere is order 42? ",
               "statements" => ["Our café is open."]
             }
    end
  end
end
