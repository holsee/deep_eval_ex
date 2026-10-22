defmodule DeepEvalEx.Metrics.TurnRelevancyTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.TurnRelevancy
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}

  @turns [
    %{role: :user, content: "My order is late."},
    %{role: :assistant, content: "Sorry! Let me check order 42."},
    %{role: :user, content: "When will it arrive?"},
    %{role: :assistant, content: "Have you tried our pizza?"},
    %{role: :user, content: "Please answer."},
    %{role: :assistant, content: "It arrives on Friday."}
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TurnRelevancy.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert TurnRelevancy.metric_name() == "Turn Relevancy"
      assert TurnRelevancy.required_params() == [:content, :role]
      assert TurnRelevancy.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "judges one sliding window per unit interaction and scores the relevant ones" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "reason,verdict" => [
                   %{"verdict" => "yes"},
                   %{"verdict" => "no", "reason" => "It advertises pizza."},
                   %{"verdict" => "yes"}
                 ],
                 "reason" => [%{"reason" => "The score is 0.67 because of message 2."}]
               })

      assert result.metric == "Turn Relevancy"
      assert result.score === 2 / 3
      assert result.success
      assert result.reason == "The score is 0.67 because of message 2."

      assert [%{verdict: :yes}, %{verdict: :no, reason: "It advertises pizza."}, %{verdict: :yes}] =
               result.metadata.verdicts

      # The default window of 10 unit interactions starts at the first turn.
      [first, second, third] = prompts("reason,verdict")
      assert first =~ "Messages:\n[{'content': 'My order is late.', 'role': 'user'}, {'content'"
      assert second =~ "{'content': 'Have you tried our pizza?', 'role': 'assistant'}]\n\nJSON:"
      assert third =~ "Messages:\n[{'content': 'My order is late.', 'role': 'user'}"

      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Relevancy Score:\n0.6666666666666666\n"

      assert reason_prompt =~
               "Irrelevancies:\n[{'message number': '2', 'reason': 'It advertises pizza.'}]\n"
    end

    test "slides a window of :window_size unit interactions" do
      assert {:ok, _result} =
               measure(
                 test_case(),
                 %{
                   "reason,verdict" => List.duplicate(%{"verdict" => "yes"}, 3),
                   "reason" => [%{"reason" => "All relevant."}]
                 },
                 window_size: 1
               )

      assert [_first, _second, third] = prompts("reason,verdict")

      assert third =~
               "Messages:\n[{'content': 'Please answer.', 'role': 'user'}, " <>
                 "{'content': 'It arrives on Friday.', 'role': 'assistant'}]\n"
    end

    test "drops a verdict outside yes and no, still counting it as a message number" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "reason,verdict" => [
                   ~s({"verdict": "maybe"}),
                   %{"verdict" => "No, it's off-topic", "reason" => "Pizza."},
                   %{"verdict" => "yes"}
                 ],
                 "reason" => [%{"reason" => "The score is 0.5."}]
               })

      assert result.score === 0.5
      assert [nil, %{verdict: :no}, %{verdict: :yes}] = result.metadata.verdicts
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "[{'message number': '2', 'reason': 'Pizza.'}]"
      assert result.verbose_logs =~ "Verdicts:\n[\n    None,\n    {\n"
    end

    test "scores the integer 1 without asking for verdicts when no user turn is answered" do
      assert {:ok, result} =
               measure(test_case([%{role: :user, content: "Hello?"}]), %{
                 "reason" => [%{"reason" => "Nothing irrelevant."}]
               })

      assert result.score === 1
      assert prompts("reason,verdict") == []
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Relevancy Score:\n1\n\nIrrelevancies:\n[]\n"
    end

    test "clamps a score below the threshold to 0 in strict mode, and skips the reason" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "reason,verdict" => [
                     %{"verdict" => "yes"},
                     %{"verdict" => "no"},
                     %{"verdict" => "yes"}
                   ]
                 },
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.threshold == 1
      assert result.reason == nil
      refute result.success
    end

    test "writes deepeval's verbose logs: the windows as Turn reprs, then the verdicts" do
      assert {:ok, result} =
               measure(
                 test_case(Enum.take(@turns, 2)),
                 %{
                   "reason,verdict" => [%{"verdict" => "yes"}],
                   "reason" => [%{"reason" => "Relevant."}]
                 }
               )

      assert result.verbose_logs ==
               "Turns Sliding Windows (size=10):\n[\n    [Turn(role='user', content='My order is late.'), " <>
                 "Turn(role='assistant', content='Sorry! Let me check order 42.')]\n] \n \n" <>
                 "Verdicts:\n[\n    {\n        \"verdict\": \"yes\",\n        \"reason\": null\n    }\n]"
    end

    test "returns deepeval's error for a single-turn test case" do
      assert {:error, :not_conversational_test_case} =
               TurnRelevancy.measure(TestCase.new!(input: "Q", actual_output: "A"),
                 adapter: :mock
               )
    end

    test "runs through the Evaluator as a module metric" do
      Mock.script(%{
        "reason,verdict" => List.duplicate(%{"verdict" => "yes"}, 3),
        "reason" => [%{"reason" => "All relevant."}]
      })

      result = Evaluator.evaluate_metric(test_case(), TurnRelevancy, adapter: :mock)
      assert result.score === 1.0
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about each turn's content and role" do
      assert %EvalSpec{
               evaluation_params: [:content, :role],
               questions: [
                 %Scored.Noul{statement: "Every assistant turn in `turns`" <> _, weight: 2.0},
                 %Scored.Noul{statement: "No assistant turn in `turns`" <> _},
                 %Scored.Score{levels: ["Mostly irrelevant" | _]}
               ]
             } = TurnRelevancy.system_one_eval_spec(test_case(), [])
    end

    test "has no System One form for a multimodal test case" do
      multimodal =
        test_case([
          %{role: :user, content: "What is this? [DEEPEVAL:IMAGE:img-1]"},
          %{role: :assistant, content: "A cat."}
        ])

      assert multimodal.multimodal
      assert TurnRelevancy.system_one_eval_spec(multimodal, []) == nil
    end

    test "hybrid asks one Noul about each window's turns; P(yes) of 0.5 and above is relevant" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.4))

      assert {:ok, result} =
               measure(test_case(), %{"reason" => [%{"reason" => "All irrelevant."}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one,
                 window_size: 1
               )

      assert result.score === 0.0
      assert [%{verdict: :no, reason: "P(yes)=0.40"} | _] = result.metadata.verdicts
      assert prompts("reason,verdict") == []

      assert [first | _] = calls = SystemOneMock.calls(system_one)
      assert length(calls) == 3
      assert Enum.map(first.questions, &elem(&1, 0)) == ["verdict"]

      assert first.state |> Jason.encode!() |> Jason.decode!() == %{
               "turns" => [
                 %{"content" => "My order is late.", "role" => "user"},
                 %{"content" => "Sorry! Let me check order 42.", "role" => "assistant"}
               ]
             }
    end

    test "system_one answers the whole metric from the turns without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               measure(test_case(), %{}, eval_mode: :system_one, system_one_model: system_one)

      assert result.success
      assert result.evaluation_model == "fake-jev"
      assert [%SystemOneMock.Call{state: state}] = SystemOneMock.calls(system_one)

      assert %{"turns" => [%{"content" => "My order is late.", "role" => "user"} | _]} =
               state |> Jason.encode!() |> Jason.decode!()

      assert Mock.scripted_prompts() == []
    end
  end
end
