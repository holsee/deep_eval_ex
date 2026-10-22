defmodule DeepEvalEx.SystemOne.ScoringTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.SystemOne.{Answers, Question, Scored, Scoring}
  alias DeepEvalEx.SystemOne.Scored.Outcome

  doctest Scoring

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  @tone Scored.Choice.new!(
          question: "What tone?",
          options: [{"friendly", 1.0}, {"neutral", 0.5}, {"rude", 0.0}, {"no_reply", nil}]
        )

  defp choice_answers(probabilities, key \\ "q_0") do
    %Answers{
      choices: %{
        key => %Answers.Choice{choice: "x", probabilities: probabilities, confidence: 0.3}
      }
    }
  end

  defp outcome(probabilities, opts \\ []) do
    struct!(
      %Outcome{question: "Q", type: :choice, weight: 1.0, applicable: true},
      [probabilities: probabilities] ++ opts
    )
  end

  describe "questions/1" do
    test "keys each wire question q_<i> in order" do
      questions = [Scored.Noul.new!(statement: "A."), @tone]

      assert [{"q_0", %Question.Noul{instructions: "A."}}, {"q_1", %Question.Choice{}}] =
               Scoring.questions(questions)
    end
  end

  describe "outcome/3" do
    test "values a Noul P(true), with a derived confidence" do
      answers = %Answers{nouls: %{"q_0" => %Answers.Noul{probability: 0.7}}}

      assert %Outcome{
               type: :noul,
               value: 0.7,
               applicable: true,
               probabilities: [{"true", 0.7}, {"false", 0.30000000000000004}],
               confidence: 0.3999999999999999
             } = Scoring.outcome(Scored.Noul.new!(statement: "A."), answers, "q_0")
    end

    test "values a Score score / (levels - 1), clamped, dropping out-of-range levels" do
      question = Scored.Score.new!(question: "How?", levels: ["Low", "Mid", "High"])

      answers = fn score ->
        %Answers{
          scores: %{
            "q_0" => %Answers.Score{
              score: score,
              probabilities: [{0, 0.1}, {1, 0.2}, {2, 0.6}, {3, 0.1}],
              confidence: 0.5
            }
          }
        }
      end

      outcome = Scoring.outcome(question, answers.(1.6), "q_0")
      assert outcome.value == 0.8
      assert outcome.probabilities == [{"Low", 0.1}, {"Mid", 0.2}, {"High", 0.6}]
      assert Scoring.outcome(question, answers.(3), "q_0").value == 1.0
      assert Scoring.outcome(question, answers.(-1), "q_0").value == 0.0
    end

    test "values a Choice the credit-weighted mean over its credited options" do
      answers = choice_answers([{"friendly", 0.35}, {"neutral", 0.45}, {"rude", 0.15}])
      outcome = Scoring.outcome(@tone, answers, "q_0")

      assert outcome.applicable
      assert outcome.value == 0.6052631578947367
      # Options keep the question's order; a missing option has probability 0.0.
      assert outcome.probabilities ==
               [{"friendly", 0.35}, {"neutral", 0.45}, {"rude", 0.15}, {"no_reply", 0.0}]
    end

    test "drops a Choice whose not-applicable options collect 0.5 of the mass" do
      at = Scoring.outcome(@tone, choice_answers([{"no_reply", 0.5}, {"friendly", 0.5}]), "q_0")
      assert %Outcome{applicable: false, value: nil} = at

      below =
        Scoring.outcome(@tone, choice_answers([{"no_reply", 0.49}, {"friendly", 0.51}]), "q_0")

      assert %Outcome{applicable: true, value: 1.0} = below
    end

    test "drops a Choice whose credited options have no mass" do
      outcome = Scoring.outcome(@tone, choice_answers([{"no_reply", 0.4}]), "q_0")
      assert %Outcome{applicable: false, value: nil} = outcome
    end

    test "raises deepeval's error for a missing answer" do
      assert_raise DeepEvalError, "Jev returned no Noul answer for q_3.", fn ->
        Scoring.outcome(Scored.Noul.new!(statement: "A."), %Answers{}, "q_3")
      end

      assert_raise DeepEvalError, "Jev returned no Choice answer for q_0.", fn ->
        Scoring.outcome(@tone, %Answers{}, "q_0")
      end
    end
  end

  describe "aggregate/1 and aggregate_strict/1" do
    test "score 1.0 when no question applies" do
      outcomes = [%Outcome{weight: 1.0, value: nil, applicable: false}]
      assert Scoring.aggregate(outcomes) === 1.0
      assert Scoring.aggregate_strict(outcomes) === 1.0
      assert Scoring.aggregate([]) === 1.0
    end

    test "strict is 1.0 only when every applicable question passed" do
      passed = %Outcome{applicable: true, passed: true}
      failed = %Outcome{applicable: true, passed: false}
      skipped = %Outcome{applicable: false, passed: nil}

      assert Scoring.aggregate_strict([passed, skipped]) === 1.0
      assert Scoring.aggregate_strict([passed, failed]) === 0.0
    end
  end

  describe "mark_strict/2" do
    test "a Noul passes from P(true) 0.5" do
      noul = Scored.Noul.new!(statement: "A.")

      for {p, passed} <- [{0.5, true}, {0.49, false}] do
        [marked] =
          Scoring.mark_strict([noul], [%Outcome{applicable: true, probabilities: [{"true", p}]}])

        assert marked.passed == passed
      end
    end

    test "a Score passes when its top level is the most likely" do
      score = Scored.Score.new!(question: "How?", levels: ["Low", "High"])

      [top, tie] =
        Scoring.mark_strict([score, score], [
          outcome([{"Low", 0.4}, {"High", 0.6}]),
          # A tie goes to the first level, as Python's max().
          outcome([{"Low", 0.5}, {"High", 0.5}])
        ])

      assert top.passed
      refute tie.passed
    end

    test "a Choice passes when its most likely credited option has full credit" do
      [friendly, neutral] =
        Scoring.mark_strict([@tone, @tone], [
          outcome([{"friendly", 0.3}, {"neutral", 0.2}, {"rude", 0.1}, {"no_reply", 0.4}]),
          outcome([{"friendly", 0.2}, {"neutral", 0.3}, {"rude", 0.1}, {"no_reply", 0.4}])
        ])

      assert friendly.passed
      refute neutral.passed
    end

    test "leaves an outcome that does not apply unmarked" do
      [marked] = Scoring.mark_strict([@tone], [outcome([], applicable: false)])
      assert marked.passed == nil
    end
  end

  describe "verbalise/1" do
    test "puts a Noul's P(true) in deepeval's bands" do
      for {p, words} <- [
            {0.85, "clearly holds"},
            {0.8499, "likely holds"},
            {0.65, "likely holds"},
            {0.6499, "unclear"},
            {0.35, "unclear"},
            {0.3499, "likely fails"},
            {0.15, "likely fails"},
            {0.1499, "clearly fails"}
          ] do
        assert Scoring.verbalise(%Outcome{type: :noul, probabilities: [{"true", p}]}) == words
      end
    end

    test "names the runner-up within 0.15 of the top answer" do
      assert Scoring.verbalise(outcome([{"a", 0.4}, {"b", 0.45}, {"c", 0.15}])) ==
               ~s("b", leaning "a")

      # 0.55 - 0.4 is 0.15000000000000002 in floats, past the margin.
      assert Scoring.verbalise(outcome([{"a", 0.4}, {"b", 0.55}, {"c", 0.05}])) == ~s("b")

      assert Scoring.verbalise(outcome([{"a", 0.2}, {"b", 0.6}, {"c", 0.2}])) == ~s("b")
      assert Scoring.verbalise(outcome([{"a", 0.5}, {"b", 0.5}])) == ~s("a", leaning "b")
      assert Scoring.verbalise(outcome([])) == "no answer"
      assert Scoring.verbalise(outcome([{"a", 1.0}], applicable: false)) == "not applicable"
    end
  end

  describe "reason/3" do
    test "says when no question applied" do
      reason =
        Scoring.reason(
          "fake-jev",
          [outcome([{"no_reply", 0.9}], applicable: false, confidence: nil, question: "Tone?")],
          score: 1.0
        )

      assert reason ==
               "Decided by fake-jev.\n1. Tone? -> not applicable (not applicable)\n" <>
                 "Score: 1.00 (no question applied to this test case)."
    end
  end

  describe "format_for_logs/1" do
    test "rounds probabilities to 3 decimals and prints Python's dict and booleans" do
      logs =
        Scoring.format_for_logs([
          %Outcome{
            question: "Q",
            type: :choice,
            weight: 1.5,
            value: nil,
            applicable: false,
            probabilities: [{"it's", 0.12345}, {"b", 0.87655}],
            confidence: 0.5,
            passed: false
          }
        ])

      assert logs ==
               "1. [choice, weight=1.5] Q\n   value=n/a applicable=False " <>
                 ~s|probabilities={"it's": 0.123, 'b': 0.877} confidence=0.500 strict_pass=False|
    end
  end

  describe "classification_reason/2" do
    test "matches the refusal classifier fixture" do
      input =
        [@fixtures, "refusal_classifier_system_one", "input.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!(objects: :ordered_objects)

      [classified] =
        [@fixtures, "refusal_classifier_system_one", "classifications.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      answers = Answers.from_dump(input["system_one"]["answers"])
      [answer] = Map.values(answers.choices)

      assert Scoring.classification_reason("fake-jev", answer) == classified["reason"]
    end

    test "leaves the alternatives out when there are none" do
      answer = %Answers.Choice{choice: "a", probabilities: [{"a", 1.0}], confidence: 1.0}

      assert Scoring.classification_reason(nil, answer) ==
               ~s|Decided by System One. Label "a" (P=1.00, confidence=1.00).|
    end
  end
end
