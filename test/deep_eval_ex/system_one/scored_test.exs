defmodule DeepEvalEx.SystemOne.ScoredTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.SystemOne.{Question, Scored}
  alias DeepEvalEx.SystemOne.Scored.{Choice, Noul, Outcome, Score}
  alias DeepEvalEx.TestRun.JSON

  doctest DeepEvalEx.SystemOne.Scored

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  describe "Noul.new!/1" do
    test "builds a Noul weighted 1.0 by default" do
      assert %Noul{statement: "`input` is a question.", weight: 1.0, true: nil, false: nil} =
               Noul.new!(statement: "`input` is a question.")
    end

    test "casts an integer weight to a float, as pydantic's float field does" do
      assert %Noul{weight: 2.0} = Noul.new!(%{statement: "x", weight: 2})
    end

    test "keeps the true and false criteria" do
      assert %Noul{true: "it is", false: "it is not"} =
               Noul.new!(statement: "x", true: "it is", false: "it is not")
    end

    test "rejects an empty statement with deepeval's message" do
      assert_raise ArgumentError, "Noul statement cannot be empty.", fn ->
        Noul.new!(statement: "  ")
      end
    end

    test "rejects a weight that is not greater than 0" do
      for weight <- [0, 0.0, -1] do
        assert_raise ArgumentError, ~r/^Noul weight must be greater than 0/, fn ->
          Noul.new!(statement: "x", weight: weight)
        end
      end
    end

    test "rejects a missing statement and an unknown field" do
      assert_raise ArgumentError, ~r/Noul statement must be a string/, fn -> Noul.new!([]) end
      assert_raise KeyError, fn -> Noul.new!(statement: "x", question: "y") end
    end
  end

  describe "Score.new!/1" do
    test "builds a Score from 2 to 10 unique levels" do
      assert %Score{question: "How?", levels: ["Low", "High"], weight: 1.0} =
               Score.new!(question: "How?", levels: ["Low", "High"])

      levels = for i <- 1..10, do: "L#{i}"
      assert %Score{levels: ^levels} = Score.new!(question: "How?", levels: levels)
    end

    test "rejects fewer than 2 or more than 10 levels with deepeval's message" do
      assert_raise ArgumentError, "Score needs between 2 and 10 levels; got 1.", fn ->
        Score.new!(question: "How?", levels: ["Only"])
      end

      assert_raise ArgumentError, "Score needs between 2 and 10 levels; got 11.", fn ->
        Score.new!(question: "How?", levels: for(i <- 1..11, do: "L#{i}"))
      end
    end

    test "rejects empty and duplicate levels with deepeval's messages" do
      assert_raise ArgumentError, "Score levels cannot be empty.", fn ->
        Score.new!(question: "How?", levels: ["a", " "])
      end

      assert_raise ArgumentError, "Score levels must be unique.", fn ->
        Score.new!(question: "How?", levels: ["a", "a"])
      end
    end

    test "rejects an empty question with deepeval's message" do
      assert_raise ArgumentError, "Score question cannot be empty.", fn ->
        Score.new!(question: "", levels: ["a", "b"])
      end
    end
  end

  describe "Choice.new!/1" do
    test "keeps the options in order, names as strings and credits as floats" do
      choice =
        Choice.new!(
          question: "Tone?",
          options: [{"friendly", 1}, {:rude, 0}, {"no_reply", nil}]
        )

      assert choice.options == [{"friendly", 1.0}, {"rude", 0.0}, {"no_reply", nil}]
      assert Choice.applicable_options(choice) == [{"friendly", 1.0}, {"rude", 0.0}]
      assert Choice.not_applicable_options(choice) == ["no_reply"]
    end

    test "rejects fewer than 2 options with deepeval's message" do
      assert_raise ArgumentError, "Choice needs at least 2 options.", fn ->
        Choice.new!(question: "Tone?", options: [{"a", 1.0}])
      end
    end

    test "rejects empty option names with deepeval's message" do
      assert_raise ArgumentError, "Choice option names cannot be empty.", fn ->
        Choice.new!(question: "Tone?", options: [{"", 1.0}, {"b", 0.0}])
      end
    end

    test "rejects a credit outside 0..1 with deepeval's message" do
      message =
        "Choice option 'a' has credit 1.5; credits must be between 0 and 1, " <>
          "or None for not applicable."

      assert_raise ArgumentError, message, fn ->
        Choice.new!(question: "Tone?", options: [{"a", 1.5}, {"b", 0}])
      end

      assert_raise ArgumentError, ~r/^Choice option 'b' has credit -1.0;/, fn ->
        Choice.new!(question: "Tone?", options: [{"a", 1}, {"b", -1}])
      end
    end

    test "rejects options that are all not applicable with deepeval's message" do
      message =
        "Choice needs at least one option with a credit; every option is None (not applicable)."

      assert_raise ArgumentError, message, fn ->
        Choice.new!(question: "Tone?", options: [{"a", nil}, {"b", nil}])
      end
    end

    test "rejects a duplicate option name" do
      assert_raise ArgumentError, ~r/Choice option names must be unique/, fn ->
        Choice.new!(question: "Tone?", options: [{"a", 1.0}, {"a", 0.0}])
      end
    end
  end

  describe "to_question/1" do
    test "a Noul asks its statement with its criteria" do
      assert Scored.to_question(Noul.new!(statement: "x", weight: 2, false: "no")) ==
               %Question.Noul{instructions: "x", true: nil, false: "no"}
    end

    test "a Score asks its question over its levels" do
      assert Scored.to_question(Score.new!(question: "How?", levels: ["Low", "High"])) ==
               %Question.Score{instructions: "How?", levels: ["Low", "High"]}
    end

    test "a Choice sends option names only, never credits" do
      choice = Choice.new!(question: "Tone?", options: [{"friendly", 1.0}, {"no_reply", nil}])

      assert Scored.to_question(choice) ==
               %Question.Choice{
                 instructions: "Tone?",
                 options: [{"friendly", nil}, {"no_reply", nil}]
               }
    end
  end

  test "text/1 is the statement of a Noul and the question of a Score or Choice" do
    assert Scored.text(Noul.new!(statement: "s")) == "s"
    assert Scored.text(Score.new!(question: "q", levels: ["a", "b"])) == "q"
    assert Scored.text(Choice.new!(question: "c", options: [{"a", 1}, {"b", 0}])) == "c"
  end

  describe "parse!/1" do
    test "parses a JSON array of questions discriminated on type, in order" do
      rendered = ~s([
        {"type": "noul", "statement": "Grounded.", "weight": 2},
        {"type": "score", "question": "How much?", "levels": ["None", "All"]},
        {"type": "choice", "question": "Tone?",
         "options": {"rude": 0, "friendly": 1.0, "no_reply": null}}
      ])

      assert [
               %Noul{statement: "Grounded.", weight: 2.0},
               %Score{question: "How much?", levels: ["None", "All"], weight: 1.0},
               %Choice{options: [{"rude", +0.0}, {"friendly", 1.0}, {"no_reply", nil}]}
             ] = Scored.parse!(rendered)
    end

    test "ignores unknown keys, as pydantic does" do
      assert [%Noul{statement: "x"}] =
               Scored.parse!(~s([{"type": "noul", "statement": "x", "note": "ignored"}]))
    end

    test "keeps the last value of a repeated option, at its first position, as json.loads does" do
      assert [%Choice{options: [{"a", 0.5}, {"b", +0.0}]}] =
               Scored.parse!(
                 ~s([{"type": "choice", "question": "q", "options": {"a": 1, "b": 0, "a": 0.5}}])
               )
    end

    test "parses an empty array" do
      assert Scored.parse!("[]") == []
    end

    @prefix "_experimental_system_one_questions must render to a JSON array of " <>
              "Noul / Score / Choice questions: "

    test "raises deepeval's DeepEvalError for invalid JSON" do
      error = assert_raise DeepEvalError, fn -> Scored.parse!("not json") end
      assert String.starts_with?(error.message, @prefix)
    end

    test "raises deepeval's DeepEvalError when the JSON is not an array" do
      assert_raise DeepEvalError, @prefix <> "Input should be a valid list", fn ->
        Scored.parse!(~s({"type": "noul"}))
      end
    end

    test "raises deepeval's DeepEvalError for an unknown or missing type" do
      assert_raise DeepEvalError,
                   @prefix <>
                     "0: Input tag 'bogus' found using 'type' does not match any of the " <>
                     "expected tags: 'noul', 'score', 'choice'",
                   fn -> Scored.parse!(~s([{"type": "bogus"}])) end

      assert_raise DeepEvalError,
                   @prefix <> "1: Unable to extract tag using discriminator 'type'",
                   fn ->
                     Scored.parse!(~s([{"type": "noul", "statement": "x"}, {"statement": "y"}]))
                   end
    end

    test "raises deepeval's DeepEvalError carrying the question's validation message" do
      assert_raise DeepEvalError,
                   @prefix <> "0.score.levels: Score needs between 2 and 10 levels; got 1.",
                   fn ->
                     Scored.parse!(~s([{"type": "score", "question": "x", "levels": ["a"]}]))
                   end
    end
  end

  describe "Outcome.to_dump/1" do
    test "dumps in QuestionOutcome's field order with string keys" do
      outcome = %Outcome{
        question: "Tone?",
        type: :choice,
        weight: 1.0,
        value: nil,
        applicable: false,
        probabilities: [{"no_reply", 0.9}, {"friendly", 0.1}]
      }

      assert JSON.encode!(Outcome.to_dump(outcome)) ==
               ~s({"question": "Tone?", "type": "choice", "weight": 1.0, "value": null, ) <>
                 ~s("applicable": false, "probabilities": {"no_reply": 0.9, "friendly": 0.1}, ) <>
                 ~s("confidence": null, "passed": null})
    end
  end

  describe "deepeval parity" do
    defp load_ordered(scenario, file) do
      [@fixtures, scenario, file]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)
    end

    defp get(%Jason.OrderedObject{values: values}, key) do
      case List.keyfind(values, key, 0) do
        {^key, value} -> value
        nil -> nil
      end
    end

    for scenario <- ~w(jev_eval jev_eval_strict_not_applicable) do
      test "#{scenario}: the parsed questions go on the wire as deepeval sent them" do
        input = load_ordered(unquote(scenario), "input.json")
        [metric] = get(input, "metrics")
        rendered = metric |> get("params") |> get("questions") |> Jason.encode!()

        questions =
          rendered
          |> Scored.parse!()
          |> Enum.with_index(fn question, i -> {"q_#{i}", Scored.to_question(question)} end)

        [[call]] = get(load_ordered(unquote(scenario), "decide.json"), "measure")

        assert JSON.encode!(Question.to_wire_map(questions)) ==
                 JSON.encode!(get(call, "questions"))
      end
    end

    test "score_breakdown outcomes dump byte for byte" do
      checked =
        for scenario <- File.ls!(@fixtures),
            File.regular?(Path.join([@fixtures, scenario, "measure.json"])),
            measure <- List.wrap(load_ordered(scenario, "measure.json")),
            breakdown = get(measure, "score_breakdown"),
            is_list(breakdown),
            dump <- breakdown do
          outcome = %Outcome{
            question: get(dump, "question"),
            type:
              Map.fetch!(
                %{"noul" => :noul, "score" => :score, "choice" => :choice},
                get(dump, "type")
              ),
            weight: get(dump, "weight"),
            value: get(dump, "value"),
            applicable: get(dump, "applicable"),
            probabilities: get(dump, "probabilities").values,
            confidence: get(dump, "confidence"),
            passed: get(dump, "passed")
          }

          assert JSON.encode!(Outcome.to_dump(outcome)) == JSON.encode!(dump), scenario
          get(dump, "type")
        end

      assert Enum.sort(Enum.uniq(checked)) == ["choice", "noul", "score"]
    end
  end
end
