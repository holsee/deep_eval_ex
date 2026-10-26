defmodule DeepEvalEx.Metrics.RoleAdherenceTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.RoleAdherence
  alias DeepEvalEx.Prompts.RoleAdherence, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}

  @role "A humble wizard who downplays his own magic."

  @turns [
    %{role: :user, content: "Show me a spell!"},
    %{role: :assistant, content: "Oh, it's only a little spark, I'm still learning..."},
    %{role: :user, content: "Something bigger!"},
    %{role: :assistant, content: "Behold, the greatest wizard alive!"}
  ]

  defp test_case(turns \\ @turns, role \\ @role),
    do: ConversationalTestCase.new!(turns: turns, chatbot_role: role)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    RoleAdherence.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0, required_params/0 and requires_chatbot_role?/0" do
    test "are deepeval's __name__, _required_test_case_params and _requires_chatbot_role" do
      assert RoleAdherence.metric_name() == "Role Adherence"
      assert RoleAdherence.required_params() == [:content, :role]
      assert RoleAdherence.requires_chatbot_role?()
      assert RoleAdherence.default_threshold() == 0.5
    end

    test "a test case without a chatbot_role is rejected" do
      assert {:error, _} = RoleAdherence.measure(ConversationalTestCase.new!(turns: @turns))
    end
  end

  describe "measure/2" do
    test "scores the share of assistant turns not out of character" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [
                   %{"verdicts" => [%{"index" => 3, "reason" => "He boasts."}]}
                 ],
                 "reason" => [%{"reason" => "The score is 0.5 because he boasts in turn #4."}]
               })

      assert result.metric == "Role Adherence"
      assert result.score === 0.5
      assert result.success
      assert result.reason == "The score is 0.5 because he boasts in turn #4."

      assert result.metadata.out_of_character_verdicts == [
               %{
                 index: 3,
                 reason: "He boasts.",
                 ai_message: "Behold, the greatest wizard alive! (turn #4)"
               }
             ]

      [verdicts_prompt] = prompts("verdicts")

      assert verdicts_prompt =~
               "Chatbot Role:\n#{@role}\n\nMessages:\n[{'content': 'Show me a spell!', 'role': 'user'}, "

      [reason_prompt] = prompts("reason")

      assert reason_prompt =~
               "Role Adherence Score:\n0.5\n\nChatbot Role:\n#{@role}\n\n" <>
                 "Out of character responses:\n['Behold, the greatest wizard alive! (turn #4)']\n"
    end

    test "keeps the judge's ai_message when the index names no turn, and counts a negative one from the end" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [
                   %{
                     "verdicts" => [
                       %{"index" => 9, "reason" => "Out of range.", "ai_message" => "Mine."},
                       %{"index" => 7, "reason" => "Out of range."},
                       %{"index" => -1, "reason" => "Boasts."}
                     ]
                   }
                 ],
                 "reason" => [%{"reason" => "Zero."}]
               })

      # Three verdicts for two assistant turns: the score stops at 0.
      assert result.score === 0.0

      assert [
               %{index: 9, ai_message: "Mine."},
               %{index: 7, ai_message: nil},
               %{index: -1, ai_message: "Behold, the greatest wizard alive! (turn #0)"}
             ] = result.metadata.out_of_character_verdicts

      [reason_prompt] = prompts("reason")

      assert reason_prompt =~
               "Out of character responses:\n['Mine.', None, " <>
                 "'Behold, the greatest wizard alive! (turn #0)']\n"
    end

    test "scores the integer 1 without assistant turns" do
      assert {:ok, result} =
               measure(test_case([%{role: :user, content: "Hello?"}]), %{
                 "verdicts" => [%{"verdicts" => []}],
                 "reason" => [%{"reason" => "Nothing said."}]
               })

      assert result.score === 1
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "verdicts" => [%{"verdicts" => [%{"index" => 3, "reason" => "Boasts."}]}],
                   "reason" => [%{"reason" => "Zero."}]
                 },
                 strict_mode: true
               )

      assert result.score === 0
      assert result.threshold == 1
    end

    test "writes deepeval's verbose logs: the role and the verdicts" do
      assert {:ok, result} =
               measure(test_case(), %{
                 "verdicts" => [%{"verdicts" => [%{"index" => 3, "reason" => "Boasts."}]}],
                 "reason" => [%{"reason" => "Half."}]
               })

      assert result.verbose_logs ==
               "Chatbot Role:\n#{@role} \n \nOut-of-Character Turn(s):\n[\n    {\n" <>
                 ~s(        "index": 3,\n        "reason": "Boasts.",\n) <>
                 ~s(        "ai_message": "Behold, the greatest wizard alive! \(turn #4\)"\n) <>
                 "    }\n]"
    end
  end

  describe "prompts" do
    test "always print the multimodal input rules" do
      assert Prompts.extract_out_of_character_response_verdicts(turns: [], role: "R") =~
               "chatbot role. \n\n\n--- MULTIMODAL INPUT RULES ---\n"

      assert Prompts.generate_reason(score: 1, role: "R", out_of_character_responses: []) =~
               "justify the score. \n\n\n\n--- MULTIMODAL INPUT RULES ---\n"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the turns and the chatbot_role" do
      assert %EvalSpec{
               evaluation_params: [:content, :role, :chatbot_role],
               questions: [
                 %Scored.Noul{
                   statement: "Every assistant turn in `turns` stays" <> _,
                   weight: 2.0
                 },
                 %Scored.Noul{statement: "No assistant turn in `turns` breaks character" <> _},
                 %Scored.Score{levels: ["Mostly out of character" | _]}
               ]
             } = RoleAdherence.system_one_eval_spec(test_case(), [])
    end

    test "hybrid asks one Noul per assistant turn, P(yes) below 0.5 out of character" do
      noul = fn p -> %Answers{nouls: %{"verdict" => %Answers.Noul{probability: p}}} end
      system_one = SystemOneMock.new(answers: [noul.(0.9), noul.(0.12)])

      assert {:ok, result} =
               measure(test_case(), %{"reason" => [%{"reason" => "Half."}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.5
      assert prompts("verdicts") == []

      assert result.metadata.out_of_character_verdicts == [
               %{
                 index: 3,
                 reason: "P(in character)=0.12",
                 ai_message: "Behold, the greatest wizard alive! (turn #4)"
               }
             ]

      assert [first, second] = SystemOneMock.calls(system_one)

      assert first.state |> Jason.encode!() |> Jason.decode!() == %{
               "chatbot_role" => @role,
               "previous_turns" => [%{"content" => "Show me a spell!", "role" => "user"}],
               "ai_message" => "Oh, it's only a little spark, I'm still learning..."
             }

      assert length(
               second.state
               |> Jason.encode!()
               |> Jason.decode!()
               |> Map.get("previous_turns")
             ) ==
               3
    end

    test "hybrid asks every turn, then lets the LLM list them all when any request fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(
                 test_case(),
                 %{
                   "verdicts" => [%{"verdicts" => []}],
                   "reason" => [%{"reason" => "In character."}]
                 },
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert length(SystemOneMock.calls(system_one)) == 2

      assert result.system_one_fallback_reason ==
               "ConnectionError: Jev is down; ConnectionError: Jev is down"
    end

    test "hybrid lets the LLM judge a conversation without assistant turns" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      assert {:ok, result} =
               measure(
                 test_case([%{role: :user, content: "Hello?"}]),
                 %{"verdicts" => [%{"verdicts" => []}], "reason" => [%{"reason" => "Nothing."}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1
      assert SystemOneMock.calls(system_one) == []
      assert [_prompt] = prompts("verdicts")
    end
  end
end
