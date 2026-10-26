defmodule DeepEvalEx.Metrics.ConversationCompletenessTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ConversationCompleteness
  alias DeepEvalEx.Prompts.ConversationCompleteness, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}

  @turns [
    %{role: :user, content: "Book a table for two on Friday, and tell me the dress code."},
    %{role: :assistant, content: "Your table for two is booked for Friday at 8pm."}
  ]

  @intentions [
    "User wants to book a table for two on Friday",
    "User wants to know the dress code"
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    ConversationCompleteness.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert ConversationCompleteness.metric_name() == "Conversation Completeness"
      assert ConversationCompleteness.required_params() == [:content, :role]
      assert ConversationCompleteness.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "extracts the user's intentions and scores the satisfied ones" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "intentions" => [%{"intentions" => @intentions}],
                 "reason,verdict" => [
                   %{"verdict" => "yes"},
                   %{"verdict" => "no", "reason" => "The dress code is never given."}
                 ],
                 "reason" => [%{"reason" => "The score is 0.5 because of the dress code."}]
               })

      assert result.metric == "Conversation Completeness"
      assert result.score === 0.5
      assert result.success
      assert result.reason == "The score is 0.5 because of the dress code."
      assert result.metadata.user_intentions == @intentions

      assert [%{verdict: :yes}, %{verdict: :no, reason: "The dress code is never given."}] =
               result.metadata.verdicts

      turns =
        "[{'content': 'Book a table for two on Friday, and tell me the dress code.', 'role': 'user'}, " <>
          "{'content': 'Your table for two is booked for Friday at 8pm.', 'role': 'assistant'}]"

      [intentions_prompt] = prompts("intentions")
      assert intentions_prompt =~ "Turns:\n#{turns}\n\nJSON:"

      [first, second] = prompts("reason,verdict")
      assert first =~ "Turns:\n#{turns}\n\nUser Intention:\n#{Enum.at(@intentions, 0)}\n"
      assert second =~ "User Intention:\n#{Enum.at(@intentions, 1)}\n"

      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Completeness Score:\n0.5\n"

      assert reason_prompt =~
               "User Intentions:\n['User wants to book a table for two on Friday', "

      assert reason_prompt =~ "Incompletenesses:\n['The dress code is never given.']\n"
    end

    test "scores the integer 1 without asking for verdicts when there are no intentions" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "intentions" => [%{"intentions" => []}],
                 "reason" => [%{"reason" => "Nothing was asked."}]
               })

      assert result.score === 1
      assert prompts("reason,verdict") == []
    end

    test "drops a verdict outside yes and no, and lists an unmet one without a reason as None" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "intentions" => [%{"intentions" => ["A", "B", "C"]}],
                 "reason,verdict" => [
                   ~s({"verdict": "unclear"}),
                   %{"verdict" => "no"},
                   %{"verdict" => "yes"}
                 ],
                 "reason" => [%{"reason" => "Half."}]
               })

      assert result.score === 0.5
      assert [nil, %{verdict: :no, reason: nil}, %{verdict: :yes}] = result.metadata.verdicts
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Incompletenesses:\n[None]\n"
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "intentions" => [%{"intentions" => @intentions}],
                   "reason,verdict" => [%{"verdict" => "yes"}, %{"verdict" => "no"}],
                   "reason" => [%{"reason" => "Unmet."}]
                 },
                 strict_mode: true
               )

      assert result.score === 0
      assert result.threshold == 1
    end

    test "takes deepeval's unused :window_size" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "intentions" => [%{"intentions" => ["A"]}],
                   "reason,verdict" => [%{"verdict" => "yes"}],
                   "reason" => [%{"reason" => "Met."}]
                 },
                 window_size: 1
               )

      assert result.score === 1.0
    end

    test "writes deepeval's verbose logs: every turn's model_dump, the intentions, the verdicts" do
      assert {:ok, result} =
               measure(
                 test_case([%{role: :user, content: "Hi", latency_ms: 80}]),
                 %{
                   "intentions" => [%{"intentions" => ["Greet"]}],
                   "reason,verdict" => [%{"verdict" => "no", "reason" => "No reply."}],
                   "reason" => [%{"reason" => "Unmet."}]
                 }
               )

      assert result.verbose_logs =~
               ~s(Turns:\n[\n    {\n        "role": "user",\n        "content": "Hi",)

      assert result.verbose_logs =~ ~s("latency_ms": 80.0,)

      assert result.verbose_logs =~
               ~s("mcp_prompts_called": null,\n        "metadata": null\n    }\n])

      assert result.verbose_logs =~
               ~s(User Intentions:\n[\n    "Greet"\n] \n \nVerdicts:\n[\n    {)
    end

    test "prints the multimodal input rules for a multimodal test case and asks no System One model" do
      multimodal =
        test_case([
          %{role: :user, content: "What is this? [DEEPEVAL:IMAGE:img-1]"},
          %{role: :assistant, content: "A cat."}
        ])

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      assert {:ok, _result} =
               measure(
                 multimodal,
                 %{
                   "intentions" => [%{"intentions" => ["Identify the picture"]}],
                   "reason,verdict" => [%{"verdict" => "yes"}],
                   "reason" => [%{"reason" => "Met."}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert SystemOneMock.calls(system_one) == []

      for prompt <- Enum.map(Mock.scripted_prompts(), & &1.prompt) do
        assert prompt =~ "\n\n\n--- MULTIMODAL INPUT RULES ---\n"
      end

      assert ConversationCompleteness.system_one_eval_spec(multimodal, []) == nil
    end
  end

  describe "prompts" do
    test "leave the multimodal input rules out by default, keeping the blank lines" do
      prompt = Prompts.generate_reason(score: 1, intentions: [], incompletenesses: [])
      assert prompt =~ "for a particular message.\n\n\n\nGiven the completeness score"
      refute prompt =~ "MULTIMODAL"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about each turn's content and role" do
      assert %EvalSpec{
               evaluation_params: [:content, :role],
               questions: [
                 %Scored.Noul{statement: "Every intention the user expresses" <> _, weight: 2.0},
                 %Scored.Noul{statement: "No user request in `turns`" <> _},
                 %Scored.Score{levels: ["None satisfied" | _]}
               ]
             } = ConversationCompleteness.system_one_eval_spec(test_case(), [])
    end

    test "hybrid asks one Noul about the turns and each intention" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.7))

      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "intentions" => [%{"intentions" => @intentions}],
                   "reason" => [%{"reason" => "Met."}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0

      assert [%{verdict: :yes, reason: "P(yes)=0.70"}, %{verdict: :yes}] =
               result.metadata.verdicts

      assert prompts("reason,verdict") == []

      assert [first, _second] = SystemOneMock.calls(system_one)

      assert first.state |> Jason.encode!() |> Jason.decode!() == %{
               "turns" => [
                 %{"content" => Enum.at(@turns, 0).content, "role" => "user"},
                 %{"content" => Enum.at(@turns, 1).content, "role" => "assistant"}
               ],
               "intention" => Enum.at(@intentions, 0)
             }
    end
  end
end
