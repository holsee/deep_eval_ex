defmodule DeepEvalEx.Metrics.KnowledgeRetentionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.KnowledgeRetention
  alias DeepEvalEx.Prompts.KnowledgeRetention, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Error, EvalSpec, Scored}
  alias Jason.OrderedObject

  @turns [
    %{role: :user, content: "I'm flying to Lisbon on 3 May."},
    %{role: :assistant, content: "Great! Where are you flying to?"},
    %{role: :user, content: "Lisbon, as I said. I'm vegetarian, too."},
    %{role: :assistant, content: "Noted: a vegetarian meal on your Lisbon flight."}
  ]

  @lisbon %{"Destination" => "Lisbon", "Date" => "3 May"}
  @diet %{"Diet" => ["Vegetarian"]}

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    KnowledgeRetention.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert KnowledgeRetention.metric_name() == "Knowledge Retention"
      assert KnowledgeRetention.required_params() == [:content, :role]
      assert KnowledgeRetention.default_threshold() == 0.5
      refute KnowledgeRetention.requires_chatbot_role?()
    end
  end

  describe "measure/2" do
    test "extracts each user turn's facts and judges each assistant turn against those before it" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "data" => [%{"data" => @lisbon}, %{"data" => @diet}],
                 "reason,verdict" => [
                   %{"verdict" => "yes", "reason" => "It asks for the destination again."},
                   %{"verdict" => "no"}
                 ],
                 "reason" => [%{"reason" => "The score is 0.50 because it forgot Lisbon once."}]
               })

      assert result.metric == "Knowledge Retention"
      assert result.score === 0.5
      assert result.success
      assert result.reason == "The score is 0.50 because it forgot Lisbon once."

      assert result.metadata.knowledges == [%{data: @lisbon}, nil, %{data: @diet}, nil]

      assert [%{verdict: :yes, reason: "It asks for the destination again."}, %{verdict: :no}] =
               result.metadata.verdicts

      [first, second] = prompts("data")

      assert first =~
               "Previous Turns:\n[]\n\nLatest User Message:\nI'm flying to Lisbon on 3 May.\n"

      assert second =~
               "Previous Turns:\n[{'content': \"I'm flying to Lisbon on 3 May.\", 'role': 'user'}, " <>
                 "{'content': 'Great! Where are you flying to?', 'role': 'assistant'}]\n\n" <>
                 "Latest User Message:\nLisbon, as I said. I'm vegetarian, too.\n"

      [first, second] = prompts("reason,verdict")

      assert first =~
               "LLM message:\nGreat! Where are you flying to?\n\n" <>
                 "Previous Knowledge:\n[{'Date': '3 May', 'Destination': 'Lisbon'}]\n\nJSON:"

      assert second =~
               "Previous Knowledge:\n[{'Date': '3 May', 'Destination': 'Lisbon'}, " <>
                 "{'Diet': ['Vegetarian']}]\n"

      [reason_prompt] = prompts("reason")

      assert reason_prompt =~
               "Attritions:\n['It asks for the destination again.']\n\n" <>
                 "Knowledge Retention Score:\n0.50\n"
    end

    test "gives no verdict to an assistant turn with no facts before it" do
      turns = [
        %{role: :assistant, content: "Hi! How can I help?"},
        %{role: :user, content: "Just saying hi."},
        %{role: :assistant, content: "Hi there!"}
      ]

      assert {:ok, result} =
               measure(test_case(turns), %{
                 "data" => [%{}],
                 "reason" => [%{"reason" => "Nothing to forget."}]
               })

      assert result.score === 1
      assert result.metadata.knowledges == [nil, %{data: nil}, nil]
      assert prompts("reason,verdict") == []
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Attritions:\n[]\n\nKnowledge Retention Score:\n1.00\n"
    end

    test "leaves an empty dict of facts out of the accumulated knowledge" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "data" => [%{"data" => %{}}, %{"data" => @diet}],
                 "reason,verdict" => [%{"verdict" => "no"}],
                 "reason" => [%{"reason" => "Retained."}]
               })

      assert result.score === 1.0
      [verdict_prompt] = prompts("reason,verdict")
      assert verdict_prompt =~ "Previous Knowledge:\n[{'Diet': ['Vegetarian']}]\n"
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "data" => [%{"data" => @lisbon}, %{"data" => @diet}],
                   "reason,verdict" => [%{"verdict" => "no"}, %{"verdict" => "yes"}],
                   "reason" => [%{"reason" => "Forgot."}]
                 },
                 strict_mode: true
               )

      assert result.score === 0
      assert result.threshold == 1
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Attritions:\n[None]\n\nKnowledge Retention Score:\n0.00\n"
    end

    test "fails, as deepeval's, to explain a verdict outside yes and no" do
      responses = %{
        "data" => [%{"data" => @lisbon}, %{"data" => @diet}],
        "reason,verdict" => [~s({"verdict": "maybe"}), %{"verdict" => "no"}]
      }

      assert_raise RuntimeError, "'NoneType' object has no attribute 'verdict'", fn ->
        measure(test_case(), responses)
      end

      assert {:ok, result} = measure(test_case(), responses, include_reason: false)
      assert result.score === 1.0
      assert [nil, %{verdict: :no}] = result.metadata.verdicts
    end

    test "writes deepeval's verbose logs: the knowledges and the verdicts" do
      assert {:ok, result} =
               measure(test_case(Enum.take(@turns, 2)), %{
                 "data" => [%{"data" => %{"Destination" => "Lisbon"}}],
                 "reason,verdict" => [%{"verdict" => "yes", "reason" => "Asks again."}],
                 "reason" => [%{"reason" => "Forgot."}]
               })

      assert result.verbose_logs ==
               ~s(Knowledges:\n[\n    {\n        "data": {\n            "Destination": "Lisbon"\n) <>
                 "        }\n    },\n    None\n] \n \n" <>
                 ~s(Verdicts:\n[\n    {\n        "verdict": "yes",\n        "reason": "Asks again."\n) <>
                 "    }\n]"
    end
  end

  describe "prompts" do
    test "always print the multimodal input rules, except the fact extraction" do
      assert Prompts.generate_verdict(llm_message: "Hi", accumulated_knowledge: []) =~
               "known facts.\n\n\n--- MULTIMODAL INPUT RULES ---\n"

      assert Prompts.generate_reason(score: 1, attritions: []) =~ "--- MULTIMODAL INPUT RULES ---"
      refute Prompts.extract_data(user_message: "Hi", previous_turns: []) =~ "MULTIMODAL"
    end

    test "print a dict of facts in its key order when it is ordered" do
      knowledge = [OrderedObject.new([{"Name", "Ann"}, {"Age", "30"}])]

      assert Prompts.generate_verdict(llm_message: "Hi", accumulated_knowledge: knowledge) =~
               "Previous Knowledge:\n[{'Name': 'Ann', 'Age': '30'}]\n"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about each turn's content and role" do
      assert %EvalSpec{
               evaluation_params: [:content, :role],
               questions: [
                 %Scored.Noul{
                   statement: "No assistant turn in `turns` forgets" <> _,
                   weight: 2.0
                 },
                 %Scored.Noul{statement: "No assistant turn in `turns` asks the user again" <> _},
                 %Scored.Score{levels: ["Forgets most facts" | _]}
               ]
             } = KnowledgeRetention.system_one_eval_spec(test_case(), [])

      multimodal = test_case([%{role: :user, content: "This? [DEEPEVAL:IMAGE:img-1]"}])
      assert KnowledgeRetention.system_one_eval_spec(multimodal, []) == nil
    end

    test "hybrid asks one Noul per judged assistant turn, P(yes) of 0.5 and above forgetting" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.62))

      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "data" => [%{"data" => @lisbon}, %{"data" => @diet}],
                   "reason" => [%{"reason" => "Forgot twice."}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0

      assert [%{verdict: :yes, reason: "P(yes)=0.62"}, %{verdict: :yes}] =
               result.metadata.verdicts

      assert prompts("reason,verdict") == []
      [reason_prompt] = prompts("reason")
      assert reason_prompt =~ "Attritions:\n['P(yes)=0.62', 'P(yes)=0.62']\n"

      assert [first, _second] = SystemOneMock.calls(system_one)

      assert first.state |> Jason.encode!() |> Jason.decode!() == %{
               "llm_message" => "Great! Where are you flying to?",
               "accumulated_knowledge" => [@lisbon]
             }
    end

    test "hybrid falls back to the LLM for each turn when the model fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "data" => [%{"data" => @lisbon}, %{"data" => @diet}],
                   "reason,verdict" => [%{"verdict" => "no"}, %{"verdict" => "no"}],
                   "reason" => [%{"reason" => "Retained."}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert length(SystemOneMock.calls(system_one)) == 2

      assert result.system_one_fallback_reason ==
               "ConnectionError: Jev is down; ConnectionError: Jev is down"
    end
  end
end
