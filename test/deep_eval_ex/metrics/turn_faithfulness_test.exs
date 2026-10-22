defmodule DeepEvalEx.Metrics.TurnFaithfulnessTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.TurnFaithfulness
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}

  @turns [
    %{role: :user, content: "Where is order 42?"},
    %{
      role: :assistant,
      content: "It shipped on 1 October.",
      retrieval_context: ["Order 42 shipped on 1 October."]
    },
    %{role: :user, content: "And a refund?"},
    %{
      role: :assistant,
      content: "Refunds take 2 days.",
      retrieval_context: ["Refunds take 5 business days."]
    }
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TurnFaithfulness.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  @window_responses %{
    "truths" => [
      %{"truths" => ["Order 42 shipped on 1 October."]},
      %{"truths" => ["Order 42 shipped on 1 October.", "Refunds take 5 business days."]}
    ],
    "claims" => [
      %{"claims" => ["Order 42 shipped on 1 October."]},
      %{"claims" => ["Order 42 shipped on 1 October.", "Refunds take 2 days."]}
    ],
    "verdicts" => [
      %{"verdicts" => [%{"verdict" => "yes"}]},
      %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no", "reason" => "5 days."}]}
    ],
    "reason" => [
      %{"reason" => "No contradictions were found."},
      %{"reason" => "Refunds take 5 business days."},
      %{"reason" => "The score is 0.75 because of the refund time."}
    ]
  }

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert TurnFaithfulness.metric_name() == "Turn Faithfulness"
      assert TurnFaithfulness.required_params() == [:role, :content, :retrieval_context]
      assert TurnFaithfulness.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "judges each window as Faithfulness does and averages the windows' scores" do
      assert {:ok, result} = measure(test_case(), @window_responses)

      assert result.metric == "Turn Faithfulness"
      assert result.score === 0.75
      assert result.success
      assert result.reason == "The score is 0.75 because of the refund time."

      assert [%{score: 1.0, claims: [_]}, %{score: 0.5, verdicts: [_, %{verdict: :no}]}] =
               result.metadata.windows

      [_first, second] = prompts("claims")
      assert second =~ "USER MESSAGE:\n\nWhere is order 42? \nAnd a refund? \n\nASSISTANT OUTPUT:"

      [_first, second] = prompts("truths")

      assert second =~
               "REFERENCE CONTEXT:\nOrder 42 shipped on 1 October.\n\nRefunds take 5 business days.\n"

      [_first, second, final] = prompts("reason")
      assert second =~ "FAITHFULNESS SCORE:\n0.50\n\nCONTRADICTIONS:\n['5 days.']\n"

      assert final =~
               "Final Score: 0.75\n\nReasons: \n['No contradictions were found.', " <>
                 "'Refunds take 5 business days.']\n\nSuccess: True\n"
    end

    test "scores a window without claims 1.0 without asking for verdicts" do
      assert {:ok, result} =
               measure(test_case(Enum.take(@turns, 2)), %{
                 "truths" => [%{"truths" => []}],
                 "claims" => [%{"claims" => []}],
                 "reason" => [%{"reason" => "Nothing to contradict."}]
               })

      assert result.score === 1.0
      assert [%{score: 1.0, reason: "<no claims to verify>"}] = result.metadata.windows
      assert prompts("verdicts") == []
    end

    test "counts borderline claims against the score with :penalize_ambiguous_claims" do
      assert {:ok, result} =
               measure(
                 test_case(Enum.take(@turns, 2)),
                 %{
                   "truths" => [%{"truths" => ["Order 42 shipped."]}],
                   "claims" => [%{"claims" => ["It shipped.", "It shipped by DHL."]}],
                   "verdicts" => [
                     %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "borderline"}]}
                   ]
                 },
                 penalize_ambiguous_claims: true,
                 include_reason: false,
                 truths_extraction_limit: 1
               )

      assert result.score === 0.5
      assert result.reason == nil
      assert [truths_prompt] = prompts("truths")
      assert truths_prompt =~ "Extract one factual, explicit truth from the REFERENCE CONTEXT."
    end

    test "clamps each window's score in strict mode, never the mean" do
      responses = Map.delete(@window_responses, "reason")

      assert {:ok, result} =
               measure(test_case(), responses, strict_mode: true, include_reason: false)

      assert result.score === 0.5
      assert result.threshold == 1
      refute result.success
      assert [%{score: 1.0}, %{score: +0.0}] = result.metadata.windows
    end

    test "scores the integer 1 without a window" do
      assert {:ok, result} = measure(test_case([%{role: :user, content: "Hello?"}]), %{})

      assert result.score === 1

      assert result.reason ==
               "There were no retrieval contexts in your turns to evaluate, hence the score is 1"
    end

    test "returns deepeval's error for a single-turn test case" do
      assert {:error, :not_conversational_test_case} =
               TurnFaithfulness.measure(TestCase.new!(input: "Q", actual_output: "A"),
                 adapter: :mock
               )
    end

    test "runs through the Evaluator as a module metric" do
      Mock.script(@window_responses)
      result = Evaluator.evaluate_metric(test_case(), TurnFaithfulness, adapter: :mock)
      assert result.score === 0.75
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about each turn's role, content and retrieval context" do
      assert %EvalSpec{
               evaluation_params: [:role, :content, :retrieval_context],
               questions: [
                 %Scored.Noul{statement: "Every factual claim" <> _, weight: 2.0},
                 %Scored.Noul{},
                 %Scored.Score{levels: ["Fabricated" | _]}
               ]
             } = TurnFaithfulness.system_one_eval_spec(test_case(), [])
    end

    test "has no System One form for a multimodal test case" do
      multimodal =
        test_case([
          %{role: :user, content: "What is this? [DEEPEVAL:IMAGE:img-1]"},
          %{role: :assistant, content: "A cat."}
        ])

      assert TurnFaithfulness.system_one_eval_spec(multimodal, []) == nil
    end

    test "hybrid asks one Noul per claim of each window about its truths" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.2))

      assert {:ok, result} =
               measure(test_case(Enum.take(@turns, 2)), Map.delete(@window_responses, "verdicts"),
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0
      assert [%{verdicts: [%{verdict: :no, reason: "P(yes)=0.20"}]}] = result.metadata.windows
      assert prompts("verdicts") == []

      assert [call] = SystemOneMock.calls(system_one)
      assert Enum.map(call.questions, &elem(&1, 0)) == ["claim_0"]

      assert call.state |> Jason.encode!() |> Jason.decode!() == %{
               "reference_context" => ["Order 42 shipped on 1 October."],
               "claims" => ["Order 42 shipped on 1 October."]
             }
    end

    test "system_one answers the whole metric from the turns without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               measure(test_case(), %{}, eval_mode: :system_one, system_one_model: system_one)

      assert result.success
      assert [%SystemOneMock.Call{state: state}] = SystemOneMock.calls(system_one)

      assert %{"turns" => [_, %{"retrieval_context" => ["Order 42 shipped on 1 October."]} | _]} =
               state |> Jason.encode!() |> Jason.decode!()

      assert Mock.scripted_prompts() == []
    end
  end
end
