defmodule DeepEvalEx.Metrics.GoalAccuracyTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.GoalAccuracy
  alias DeepEvalEx.Prompts.GoalAccuracy, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}

  @turns [
    %{role: :user, content: "Book a table for two on Saturday."},
    %{
      role: :assistant,
      content: "Checking Saturday.",
      tools_called: [%{name: "check_availability", input_parameters: %{"day" => "Saturday"}}]
    },
    %{role: :assistant, content: "Booked for 19:00."},
    %{role: :user, content: "Thanks! The address?"},
    %{role: :assistant, content: "12 Rue de l'Odéon."}
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    GoalAccuracy.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  defp score(score, reason), do: %{"score" => score, "reason" => reason}

  @scores %{
    "reason,score" => [
      %{"score" => 1, "reason" => "Booked."},
      %{"score" => 0.5, "reason" => "No postcode."},
      %{"score" => 0.75, "reason" => "Checked, then booked."},
      %{"score" => 1.0, "reason" => "Direct."}
    ],
    "text" => ["Passed: both goals were met."]
  }

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert GoalAccuracy.metric_name() == "Goal Accuracy"
      assert GoalAccuracy.required_params() == [:role, :content]
      refute GoalAccuracy.requires_chatbot_role?()
      assert GoalAccuracy.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the mean of the mean goal score and the mean plan score" do
      assert {:ok, result} = measure(test_case(), @scores)

      assert result.metric == "Goal Accuracy"
      # ((1.0 + 0.5) / 2 + (0.75 + 1.0) / 2) / 2
      assert result.score === 0.8125
      assert result.success
      assert result.reason == "Passed: both goals were met."

      assert result.metadata.goal_scores == [
               %{score: 1.0, reason: "Booked."},
               %{score: 0.5, reason: "No postcode."}
             ]
    end

    test "asks each goal, then each plan, about the unit's accumulated steps" do
      assert {:ok, _result} = measure(test_case(), @scores)

      [goal, _goal, plan, _plan] = prompts("reason,score")

      steps =
        "AGENT STEPS:\nAssistant messages: \nChecking Saturday. \nTools called: \n[\n  {\n" <>
          "      \"name\": \"check_availability\",\n"

      assert goal =~ "assessing the **goal accuracy**"

      assert goal =~
               "USER TASK:\nUser messages: \nBook a table for two on Saturday.\n\n\n" <> steps

      assert goal =~
               "  }\n] \n\nAssistant messages: \nChecking Saturday. \nTools called: \n[\n"

      assert goal =~ "  }\n] \nBooked for 19:00. \n\n\nJSON:"
      assert plan =~ "assessing the **planning quality**"
    end

    test "writes the final reason as plain text from every score, scores printed as floats" do
      assert {:ok, _result} = measure(test_case(), @scores)

      [reason] = prompts("text")

      assert reason =~
               "Goal evaluations:\nScore: 1.0, Reason: Booked.Score: 0.5, Reason: No postcode.\n\n" <>
                 "Plan evaluations:\nScore: 0.75, Reason: Checked, then booked. \n" <>
                 "Score: 1.0, Reason: Direct. \n\n\nFinal Score: 0.8125\nThreshold: 0.5\nResult: PASS\n"
    end

    test "writes the reason even with include_reason: false, as deepeval does" do
      assert {:ok, result} = measure(test_case(), @scores, include_reason: false)
      assert result.reason == "Passed: both goals were met."
    end

    test "scores 0.0 without a unit interaction, and still explains" do
      assert {:ok, result} =
               measure(test_case([%{role: :user, content: "Hello?"}]), %{"text" => ["Nothing."]})

      assert result.score === 0.0
      assert prompts("reason,score") == []
    end

    test "clamps a score below the threshold to the integer 0 in strict mode" do
      assert {:ok, result} = measure(test_case(), @scores, strict_mode: true)

      assert result.score === 0
      assert result.threshold == 1
      [reason] = prompts("text")
      assert reason =~ "Final Score: 0\nThreshold: 1\nResult: FAIL\n"
    end

    test "writes deepeval's verbose logs, its \"c\" included" do
      assert {:ok, result} =
               measure(
                 test_case([
                   %{role: :user, content: "Hi"},
                   %{role: :assistant, content: "Hello"}
                 ]),
                 %{
                   "reason,score" => [score(1.0, "G"), score(0.5, "P")],
                   "text" => ["R"]
                 }
               )

      assert result.verbose_logs ==
               ~s|Goals and steps taken: \nUser messages: \nHi\n \nc[\n    "Assistant messages: \nHello \n"\n] \n\n \n| <>
                 ~s| \n \nGoal evaluations: [\n    {\n        "score": 1.0,\n        "reason": "G"\n    }\n] \n\n| <>
                 ~s|Plan evaluations: [\n    {\n        "score": 0.5,\n        "reason": "P"\n    }\n] \n\n| <>
                 ~s|Final Score: 0.75|
    end
  end

  describe "prompts" do
    test "print the multimodal input rules only for a multimodal conversation" do
      refute Prompts.get_accuracy_score(task: "T", steps_taken: "S") =~ "MULTIMODAL"

      assert Prompts.get_accuracy_score(task: "T", steps_taken: "S", multimodal: true) =~
               "user-visible.\n\n\n--- MULTIMODAL INPUT RULES ---\n"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the turns and their tools" do
      assert %EvalSpec{
               evaluation_params: [:role, :content, :tools_called],
               questions: [
                 %Scored.Noul{statement: "Every goal the user states" <> _, weight: 2.0},
                 %Scored.Score{levels: ["Not achieved" | _]},
                 %Scored.Score{levels: ["No plan" | _]}
               ]
             } = GoalAccuracy.system_one_eval_spec(test_case(), [])
    end

    test "has no System One form for a multimodal conversation" do
      multimodal = %{test_case() | multimodal: true}
      assert GoalAccuracy.system_one_eval_spec(multimodal, []) == nil
    end

    test "hybrid scores each goal, then each plan, with one Score each; the LLM explains" do
      probabilities = for level <- 0..4, do: {level, 0.2}

      level = fn score ->
        %Answers{
          scores: %{
            "verdict" => %Answers.Score{
              score: score,
              probabilities: probabilities,
              confidence: 0.4
            }
          }
        }
      end

      system_one = SystemOneMock.new(answers: [level.(4), level.(2), level.(3), level.(1)])

      assert {:ok, result} =
               measure(test_case(), %{"text" => ["R"]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      # ((1.0 + 0.5) / 2 + (0.75 + 0.25) / 2) / 2
      assert result.score === 0.625
      assert prompts("reason,score") == []

      assert [%{reason: "Decided by " <> goal}, _] = result.metadata.goal_scores
      assert goal =~ ": goal accuracy 1.00, confidence 0.40."
      assert [%{reason: "Decided by " <> plan}, _] = result.metadata.plan_scores
      assert plan =~ ": plan quality 0.75, confidence 0.40."

      assert [first | _] = SystemOneMock.calls(system_one)

      assert first.state |> Jason.encode!() |> Jason.decode!() |> Map.keys() |> Enum.sort() ==
               ["steps_taken", "task"]
    end

    test "hybrid falls back to the LLM per score when the request fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(test_case(), @scores, eval_mode: :hybrid, system_one_model: system_one)

      assert result.score === 0.8125
      assert length(SystemOneMock.calls(system_one)) == 4
      assert result.system_one_fallback_reason =~ "ConnectionError: Jev is down; "
    end
  end
end
